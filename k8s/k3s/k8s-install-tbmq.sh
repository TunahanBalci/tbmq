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

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/k8s-common.sh"

check_cluster
check_default_storage_class

# configure namespace
apply_namespace

# install PostgreSQL
kube apply -f postgres.yml

# install Kafka
kube apply -f kafka.yml

# install Valkey
kube apply -f valkey.yml

log "Waiting for third-party components to become ready (timeout ${WAIT_TIMEOUT})..."
kube rollout status deployment/postgres --timeout="${WAIT_TIMEOUT}"
kube rollout status statefulset/tbmq-kafka --timeout="${WAIT_TIMEOUT}"
kube rollout status deployment/tbmq-valkey --timeout="${WAIT_TIMEOUT}"

# install TBMQ
run_db_setup INSTALL_TB

log "TBMQ installation finished. Run ./k8s-deploy-tbmq.sh to start TBMQ."
