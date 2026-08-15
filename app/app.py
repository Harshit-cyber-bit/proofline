"""The demo service.

Small on purpose -- the interesting engineering in this repo is the pipeline
around it, not the application. But two things here are load-bearing for the
zero-downtime claim, and both are the things demo apps usually get wrong:

1.  Readiness and liveness are *different endpoints with different meanings*.
    Liveness answers "is this process wedged"; readiness answers "should traffic
    come here right now". Wiring both to the same handler is the most common way
    to turn a rolling update into an outage.

2.  SIGTERM flips readiness to false and then keeps serving. Kubernetes sends
    SIGTERM and removes the pod from endpoints *concurrently*, not in sequence,
    so a process that exits immediately on SIGTERM drops the requests already in
    flight and the ones the proxies have not stopped sending yet. Dropping them
    is exactly what the prober is built to catch.
"""

from __future__ import annotations

import logging
import os
import random
import signal
import threading
import time

from flask import Flask, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

VERSION = os.environ.get("APP_VERSION", "dev")
ENVIRONMENT = os.environ.get("APP_ENVIRONMENT", "local")

# How long to keep serving after SIGTERM before letting the process exit. Must
# be comfortably longer than the time it takes every kube-proxy and ingress to
# notice this pod has left the endpoint list. 15s is generous for a demo; tune
# it against your own dataplane.
DRAIN_SECONDS = float(os.environ.get("APP_DRAIN_SECONDS", "15"))

# Fault injection, used to make SLOs burn on demand. Never set in prod.
ERROR_RATE = float(os.environ.get("APP_ERROR_RATE", "0"))
LATENCY_MS = float(os.environ.get("APP_EXTRA_LATENCY_MS", "0"))

log = logging.getLogger("app")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

app = Flask(__name__)

REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests.",
    ["method", "path", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency.",
    ["method", "path"],
    # Buckets chosen around the 250ms latency SLO objective, so the SLO query
    # lands on a real bucket boundary instead of interpolating across one.
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
READY = Gauge("app_ready", "1 when the app is accepting traffic.")
BUILD = Gauge("app_build_info", "Build metadata.", ["version", "environment"])

BUILD.labels(version=VERSION, environment=ENVIRONMENT).set(1)

_ready = threading.Event()
_ready.set()
READY.set(1)


def _drain(signum, _frame) -> None:
    """Stop advertising readiness, then keep serving until the drain elapses."""
    log.info("signal %s received: draining for %ss", signum, DRAIN_SECONDS)
    _ready.clear()
    READY.set(0)

    def _exit() -> None:
        time.sleep(DRAIN_SECONDS)
        log.info("drain complete, exiting")
        os._exit(0)

    threading.Thread(target=_exit, daemon=True).start()


signal.signal(signal.SIGTERM, _drain)
signal.signal(signal.SIGINT, _drain)


@app.before_request
def _start_timer() -> None:
    request.environ["_start"] = time.perf_counter()


@app.after_request
def _record(response):
    # Use the matched rule rather than the raw path, so that a high-cardinality
    # URL space cannot explode the metric's label cardinality.
    path = request.url_rule.rule if request.url_rule else "unmatched"
    elapsed = time.perf_counter() - request.environ.get("_start", time.perf_counter())
    REQUESTS.labels(request.method, path, response.status_code).inc()
    LATENCY.labels(request.method, path).observe(elapsed)
    return response


@app.get("/")
def index():
    return jsonify(
        service="proofline-demo",
        version=VERSION,
        environment=ENVIRONMENT,
        ready=_ready.is_set(),
    )


@app.get("/healthz")
def healthz():
    """Liveness: is this process still functioning?

    Deliberately independent of readiness. A pod that is draining is not
    unhealthy, and answering 503 here would make the kubelet kill it mid-drain
    -- turning a graceful shutdown back into dropped requests.
    """
    return jsonify(status="ok"), 200


@app.get("/readyz")
def readyz():
    """Readiness: should this pod receive traffic right now?"""
    if _ready.is_set():
        return jsonify(status="ready"), 200
    return jsonify(status="draining"), 503


@app.get("/api/work")
def work():
    """A unit of pretend work, with optional injected faults.

    The fault knobs exist so that `make burn` can drive the SLO into a real
    error-budget breach and prove the pipeline's promotion gate actually blocks.
    A gate nobody has watched fail is not a gate.
    """
    if LATENCY_MS:
        time.sleep(LATENCY_MS / 1000.0)

    if ERROR_RATE and random.random() < ERROR_RATE:
        return jsonify(error="injected failure"), 500

    return jsonify(result="ok", version=VERSION)


@app.get("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


if __name__ == "__main__":  # pragma: no cover - production runs gunicorn
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
