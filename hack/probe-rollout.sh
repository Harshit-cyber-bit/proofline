#!/usr/bin/env bash
# Probe a service for the duration of its rollout.
#
# Port-forwards to the *Service* rather than to a pod, deliberately. Probing a
# single pod would miss the thing worth measuring: the window where a pod has
# stopped serving but is still in the endpoint list, so the Service is still
# sending it traffic. That gap is where dropped requests live.
#
# Usage: probe-rollout.sh <kube-context> <namespace> <local-port> <report-path> [duration]
#
# With a duration, probes for that many seconds. Without one, probes until
# `kubectl rollout status` returns, plus a tail to catch the old pods finishing
# their termination.
set -o errexit
set -o nounset
set -o pipefail

CONTEXT="${1:?usage: probe-rollout.sh <context> <namespace> <port> <report> [duration]}"
NAMESPACE="${2:?namespace required}"
PORT="${3:?local port required}"
REPORT="${4:?report path required}"
DURATION="${5:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$(dirname "${REPORT}")"

kubectl --context "${CONTEXT}" port-forward \
  -n "${NAMESPACE}" svc/proofline "${PORT}:80" >/dev/null 2>&1 &
FORWARD_PID=$!

cleanup() {
  kill "${FORWARD_PID}" 2>/dev/null || true
  wait "${FORWARD_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for the forward to be usable rather than sleeping a guessed amount. A
# probe that starts before the tunnel is up records its own startup as an
# outage.
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [ -n "${DURATION}" ]; then
  python3 "${REPO_ROOT}/prober/prober.py" \
    --url "http://127.0.0.1:${PORT}/api/work" \
    --duration "${DURATION}" \
    --interval 0.1 \
    --report "${REPORT}"
else
  python3 "${REPO_ROOT}/prober/prober.py" \
    --url "http://127.0.0.1:${PORT}/api/work" \
    --interval 0.2 \
    --until-command "kubectl --context ${CONTEXT} rollout status deployment/proofline -n ${NAMESPACE} --timeout=300s" \
    --report "${REPORT}"
fi
