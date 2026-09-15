#!/bin/bash
#
# Copyright © 2016-2026 The Thingsboard Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Shared helpers for the k3s deployment scripts. Sourced, not executed.
#
# Supported environment variables:
#   KUBECONFIG           - kubeconfig to use. Falls back to /etc/rancher/k3s/k3s.yaml when no other config is found.
#   TBMQ_INGRESS_CLASS   - IngressClass for the Web UI ingress. Auto-detected when unset; "none" skips the ingress.
#   TBMQ_WAIT_TIMEOUT    - timeout used while waiting for pods and rollouts (default: 600s).

set -euo pipefail

NAMESPACE="thingsboard-mqtt-broker"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
WAIT_TIMEOUT="${TBMQ_WAIT_TIMEOUT:-600s}"
NODE_PORTS=(30001 30002 30003 30004)

# All manifests are referenced relative to the scripts folder, so the scripts can be run from any directory.
cd "$(dirname "${BASH_SOURCE[0]}")"

log() {
  echo "[tbmq-k3s] $*"
}

fail() {
  echo "[tbmq-k3s] ERROR: $*" >&2
  exit 1
}

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL=(kubectl)
elif command -v k3s >/dev/null 2>&1; then
  KUBECTL=(k3s kubectl)
else
  fail "Neither 'kubectl' nor 'k3s' was found in PATH."
fi

# A standalone kubectl does not know about the k3s kubeconfig, so point it there when nothing else is configured.
if [ -z "${KUBECONFIG:-}" ] && [ ! -f "${HOME}/.kube/config" ] && [ -f "${K3S_KUBECONFIG}" ]; then
  if [ -r "${K3S_KUBECONFIG}" ]; then
    export KUBECONFIG="${K3S_KUBECONFIG}"
  else
    fail "${K3S_KUBECONFIG} is not readable by $(id -un). Either run the script with sudo, or copy the config for your user:
  mkdir -p ~/.kube && sudo k3s kubectl config view --raw > ~/.kube/config && chmod 600 ~/.kube/config"
  fi
fi

# Every call is scoped to the TBMQ namespace explicitly, the kubeconfig current context is never modified.
kube() {
  "${KUBECTL[@]}" -n "${NAMESPACE}" "$@"
}

check_cluster() {
  if ! "${KUBECTL[@]}" get --raw /readyz >/dev/null 2>&1; then
    fail "Unable to reach the Kubernetes API server with '${KUBECTL[*]}'. Make sure k3s is running and KUBECONFIG points to the k3s cluster."
  fi
}

check_default_storage_class() {
  local default_sc
  default_sc=$("${KUBECTL[@]}" get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')
  if [ -z "${default_sc}" ]; then
    fail "No default StorageClass found. PostgreSQL and Kafka need persistent volumes; enable the k3s local-path provisioner or mark a StorageClass as default."
  fi
  log "Using default StorageClass: $(echo "${default_sc}" | head -n 1)"
}

apply_namespace() {
  "${KUBECTL[@]}" apply -f tbmq-namespace.yml
}

# Runs the one-off TBMQ database setup pod with the given mode (INSTALL_TB or UPGRADE_TB) and propagates its exit code.
run_db_setup() {
  local mode_env="$1"
  local rc=0

  kube apply -f tbmq-configmap.yml
  kube delete pod tb-db-setup --ignore-not-found=true --wait=true
  kube apply -f database-setup.yml
  trap 'kube delete pod tb-db-setup --ignore-not-found=true --wait=false >/dev/null 2>&1 || true' EXIT

  log "Waiting for pod/tb-db-setup to become ready (timeout ${WAIT_TIMEOUT})..."
  if ! kube wait --for=condition=Ready pod/tb-db-setup --timeout="${WAIT_TIMEOUT}"; then
    kube describe pod tb-db-setup || true
    fail "pod/tb-db-setup did not become ready."
  fi

  kube exec tb-db-setup -- sh -c "export ${mode_env}=true; start-tb-mqtt-broker.sh; rc=\$?; touch /tmp/install-finished; exit \$rc" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    fail "TBMQ database setup (${mode_env}) failed with exit code ${rc}. See the output above for details."
  fi
}

check_node_ports_available() {
  local used port
  used=$("${KUBECTL[@]}" get svc -A \
    -o jsonpath='{range .items[*]}{range .spec.ports[*]}{.nodePort}{" "}{end}{"\t"}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
    | awk -F'\t' -v self="${NAMESPACE}/tbmq" '$2 != self {print $1}')
  for port in "${NODE_PORTS[@]}"; do
    if echo "${used}" | tr ' ' '\n' | grep -qx "${port}"; then
      fail "NodePort ${port} is already allocated by another service. Free it or change the nodePort values in tbmq.yml."
    fi
  done
}

detect_ingress_class() {
  local classes
  if [ -n "${TBMQ_INGRESS_CLASS:-}" ]; then
    echo "${TBMQ_INGRESS_CLASS}"
    return
  fi
  classes=$("${KUBECTL[@]}" get ingressclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [ -z "${classes}" ]; then
    classes=$("${KUBECTL[@]}" get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    if [ "$(echo "${classes}" | grep -c .)" -gt 1 ]; then
      log "Multiple IngressClasses found and none is default; set TBMQ_INGRESS_CLASS to choose one." >&2
      classes=""
    fi
  fi
  echo "${classes}" | head -n 1
}

apply_ingress() {
  local ingress_class
  ingress_class=$(detect_ingress_class)
  if [ "${ingress_class}" = "none" ]; then
    log "TBMQ_INGRESS_CLASS=none, skipping ingress."
  elif [ -z "${ingress_class}" ]; then
    log "No IngressClass available (Traefik disabled?), skipping ingress. The Web UI is still reachable via NodePort."
  else
    log "Applying ingress with IngressClass '${ingress_class}'."
    sed "s/ingressClassName: traefik/ingressClassName: ${ingress_class}/" routes.yml | kube apply -f -
  fi
}

print_access_info() {
  local node_ip
  node_ip=$("${KUBECTL[@]}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  log "TBMQ endpoints (any k3s node IP works, e.g. ${node_ip}):"
  log "  Web UI:          http://${node_ip}:30001"
  log "  MQTT:            ${node_ip}:30002"
  log "  MQTT over SSL:   ${node_ip}:30003 (requires SSL listener configuration)"
  log "  MQTT over WS:    ws://${node_ip}:30004/mqtt"
  if kube get ingress tbmq-ingress >/dev/null 2>&1; then
    log "  Web UI (ingress): http://<ingress-address>/"
  fi
}
