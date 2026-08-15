#!/usr/bin/env bash
# Create a kind cluster wired to a local image registry.
#
# The upstream kind local-registry recipe, kept close to its documented shape:
#   https://kind.sigs.k8s.io/docs/user/local-registry/
#
# Three worker nodes rather than one, because the things this repo measures --
# rolling updates, PodDisruptionBudgets, topology spread -- are all no-ops on a
# single-node cluster. A zero-downtime test that passes because there was
# nowhere else to schedule has proven nothing.
set -o errexit
set -o nounset
set -o pipefail

CLUSTER_NAME="${CLUSTER_NAME:-proofline}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"

if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != 'true' ]; then
  echo "==> starting local registry on localhost:${REGISTRY_PORT}"
  docker run -d --restart=always \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --network bridge \
    --name "${REGISTRY_NAME}" \
    registry:2
else
  echo "==> local registry already running"
fi

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "==> kind cluster '${CLUSTER_NAME}' already exists"
else
  echo "==> creating kind cluster '${CLUSTER_NAME}'"
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  # NodePorts for Prometheus, Grafana and Alertmanager, so the SLO gate and the
  # dashboards are reachable from the host without another port-forward.
  - containerPort: 30090
    hostPort: 30090
    protocol: TCP
  - containerPort: 30300
    hostPort: 30300
    protocol: TCP
  - containerPort: 30903
    hostPort: 30903
    protocol: TCP
- role: worker
- role: worker
- role: worker
EOF
fi

REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${REGISTRY_NAME}:5000"]
EOF
done

if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}")" = 'null' ]; then
  docker network connect "kind" "${REGISTRY_NAME}"
fi

cat <<EOF | kubectl --context "kind-${CLUSTER_NAME}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo "==> cluster '${CLUSTER_NAME}' ready, registry at localhost:${REGISTRY_PORT}"
