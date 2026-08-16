#!/usr/bin/env bash
# Probe a service for the duration of its rollout.
#
# Hits the Service's NodePort on localhost, which kind maps through to the
# cluster. That path goes through kube-proxy, which load balances across every
# ready endpoint -- the same path real traffic takes.
#
# An earlier version of this script used `kubectl port-forward svc/proofline`.
# That was wrong, and wrong in a way that inverted the result: port-forward
# resolves the Service to ONE backing pod and tunnels to it. When a rollout
# replaced that pod the tunnel died, and the prober reported ~18 seconds of
# downtime on a rollout that never dropped a single real request. Meanwhile the
# genuinely unsafe overlay happened to keep its tunnel alive and "passed".
#
# The lesson generalises: measure through the same path your users take, or you
# are measuring your test harness.
#
# Usage: probe-rollout.sh <kube-context> <namespace> <node-port> <report> [duration]
set -o errexit
set -o nounset
set -o pipefail

CONTEXT="${1:?usage: probe-rollout.sh <context> <namespace> <node-port> <report> [duration]}"
NAMESPACE="${2:?namespace required}"
PORT="${3:?node port required}"
REPORT="${4:?report path required}"
DURATION="${5:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="http://127.0.0.1:${PORT}"

mkdir -p "$(dirname "${REPORT}")"

# Wait for the service to answer before starting, rather than sleeping a
# guessed amount. A probe that starts too early records its own startup as an
# outage.
ready=false
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "${BASE_URL}/healthz" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done

if [ "${ready}" != "true" ]; then
  echo "service not reachable at ${BASE_URL} after 60s." >&2
  echo "Check the NodePort is mapped: kubectl --context ${CONTEXT} get svc -n ${NAMESPACE} proofline" >&2
  echo "If the cluster predates the NodePort change, recreate it: make down && make cluster" >&2
  exit 1
fi

if [ -n "${DURATION}" ]; then
  python3 "${REPO_ROOT}/prober/prober.py" \
    --url "${BASE_URL}/api/work" \
    --duration "${DURATION}" \
    --interval 0.1 \
    --report "${REPORT}"
  exit $?
fi

# Trigger the rollout from inside the probe window. Doing it beforehand loses
# the race that matters: the pods may already have cycled before the first
# request goes out.
if [ "${ROLLOUT_RESTART:-1}" = "1" ]; then
  TRIGGER="kubectl --context ${CONTEXT} rollout restart deployment/proofline -n ${NAMESPACE} && "
else
  TRIGGER=""
fi

python3 "${REPO_ROOT}/prober/prober.py" \
  --url "${BASE_URL}/api/work" \
  --interval 0.2 \
  --until-command "/bin/sh -c '${TRIGGER}kubectl --context ${CONTEXT} rollout status deployment/proofline -n ${NAMESPACE} --timeout=300s'" \
  --report "${REPORT}"
