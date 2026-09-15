# TBMQ K3s deployment scripts

This folder contains scripts and Kubernetes resources configurations to run TBMQ on a [K3s](https://k3s.io/) cluster.

The setup mirrors the [Minikube deployment](../minikube) (PostgreSQL, Kafka and Valkey running inside the cluster),
adapted to the defaults of a K3s installation:

* no Minikube addons are required: persistent volumes are provisioned by the built-in `local-path` storage class;
* the Web UI ingress targets Traefik (the K3s default ingress controller) and is skipped automatically when no
  IngressClass is available, e.g. when K3s runs with `--disable traefik`;
* TBMQ is always reachable via NodePort services, so neither ServiceLB nor an ingress controller is required;
* the scripts never modify your kubeconfig context; every command is scoped to the `thingsboard-mqtt-broker` namespace;
* the scripts stop on the first error, including a failed TBMQ database installation or upgrade.

## Prerequisites

* A running K3s cluster (single or multi node) with a default StorageClass (`local-path` is enabled by default).
  Tested with K3s `v1.36.4+k3s1`.
* `kubectl` (or the `k3s kubectl` bundled with K3s) with access to the cluster.
  When `KUBECONFIG` is not set and `~/.kube/config` does not exist, the scripts use `/etc/rancher/k3s/k3s.yaml`.
  That file is readable by root only, so either run the scripts with `sudo` or copy the config for your user:

  ```bash
  mkdir -p ~/.kube && sudo k3s kubectl config view --raw > ~/.kube/config && chmod 600 ~/.kube/config
  ```
* NodePorts `30001`-`30004` are free.
* Enough resources for TBMQ (2 replicas), TBMQ Integration Executor, Kafka, PostgreSQL and Valkey; at least 4 CPU
  cores and 8GB of RAM are recommended.

## Installation

Clone the repository and navigate to this folder:

```bash
git clone -b release-2.4.0 https://github.com/thingsboard/tbmq.git
cd tbmq/k8s/k3s
```

Install third-party components and initialize the TBMQ database:

```bash
./k8s-install-tbmq.sh
```

Deploy TBMQ:

```bash
./k8s-deploy-tbmq.sh
```

The deploy script waits until all TBMQ pods are ready and prints the endpoints.

## Access

Use the IP address of any K3s node:

| Endpoint     | Address                         |
|--------------|---------------------------------|
| Web UI       | `http://<node-ip>:30001`        |
| MQTT         | `<node-ip>:30002`               |
| MQTT over SSL| `<node-ip>:30003` (SSL listener must be configured first) |
| MQTT over WS | `ws://<node-ip>:30004/mqtt`     |

When an ingress controller is available, the Web UI is also served at `http://<ingress-address>/`.

Default System Administrator credentials: `sysadmin@thingsboard.org` / `sysadmin`.

Check the pods:

```bash
kubectl -n thingsboard-mqtt-broker get pods
```

## Configuration

| Environment variable | Description                                                                                          | Default                  |
|----------------------|------------------------------------------------------------------------------------------------------|--------------------------|
| `TBMQ_INGRESS_CLASS` | IngressClass for the Web UI ingress. Use `none` to skip the ingress.                                  | default/only IngressClass |
| `TBMQ_WAIT_TIMEOUT`  | Timeout for pod readiness and rollouts (increase on slow networks, image pulls are large).           | `600s`                   |
| `KUBECONFIG`         | Kubeconfig to use.                                                                                   | `~/.kube/config`, then `/etc/rancher/k3s/k3s.yaml` |

Example: `TBMQ_INGRESS_CLASS=nginx ./k8s-deploy-tbmq.sh`.

## Upgrade

Update the image versions in `tbmq.yml`, `tbmq-ie.yml` and `database-setup.yml`, then run:

```bash
./k8s-delete-tbmq.sh
./k8s-upgrade-tbmq.sh
./k8s-deploy-tbmq.sh
```

## Removal

Remove TBMQ only (third-party components and data are kept):

```bash
./k8s-delete-tbmq.sh
```

Remove all resources, **including PostgreSQL and Kafka data**:

```bash
./k8s-delete-all.sh
```

Optionally remove the namespace afterwards:

```bash
kubectl delete namespace thingsboard-mqtt-broker
```

## Backup and restore

See [backup-restore/README.md](backup-restore/README.md).
