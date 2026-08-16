#!/usr/bin/env python3
"""Confirm Prometheus is scraping the application, before trusting the SLO gate.

Worth its own script for two reasons.

First, the query is easy to get wrong by hand. `up{job="proofline"}` contains
braces and quotes, which must be percent-encoded; pasted straight into a URL,
Prometheus answers `parse error: unexpected "="` and it looks like the query is
malformed rather than the transport.

Second, and more importantly: if this returns nothing, the SLO gate will report
"no data" and block every promotion. That is the gate behaving correctly, but
the cause is upstream, and debugging the gate instead of the scrape wastes an
evening. Run this first.

Usage: python3 hack/prom-check.py [--prometheus URL] [--job NAME]
       make prom-check
"""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.parse
import urllib.request

GREEN, RED, YELLOW, DIM, BOLD, RESET = (
    "\033[32m",
    "\033[31m",
    "\033[33m",
    "\033[2m",
    "\033[1m",
    "\033[0m",
)


def get(base: str, path: str, params: dict | None = None, timeout: float = 15.0):
    url = f"{base.rstrip('/')}{path}"
    if params:
        # urlencode is the whole point: it escapes the braces and quotes that
        # make a hand-written PromQL URL fail.
        url = f"{url}?{urllib.parse.urlencode(params)}"

    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prometheus", default="http://localhost:30090")
    parser.add_argument("--job", default="proofline")
    args = parser.parse_args()

    base = args.prometheus

    # 1. reachable?
    try:
        with urllib.request.urlopen(f"{base}/-/healthy", timeout=10):
            pass
    except Exception as exc:
        print(f"  {RED}FAIL{RESET} Prometheus not reachable at {base}: {exc}")
        print()
        print("  Is the monitoring stack installed?  make terraform-local")
        print("  Is the NodePort mapped?  docker port proofline-control-plane")
        return 1
    print(f"  {GREEN}ok{RESET}   Prometheus reachable at {base}")

    # 2. what jobs exist at all? The fastest way to see a jobLabel mistake.
    try:
        jobs = get(base, "/api/v1/label/job/values").get("data", [])
    except Exception as exc:
        print(f"  {RED}FAIL{RESET} could not list job labels: {exc}")
        return 1

    print()
    print(f"  {BOLD}job labels Prometheus knows about:{RESET}")
    for job in sorted(jobs):
        marker = f"{GREEN}<-- ours{RESET}" if job == args.job else ""
        print(f"      {job} {marker}")

    if args.job not in jobs:
        print()
        print(f"  {RED}FAIL{RESET} no job named {args.job!r}.")
        print()
        print("  The ServiceMonitor's jobLabel is not resolving. It reads")
        print("  app.kubernetes.io/name off the *Service*, so check:")
        print()
        print("      kubectl get servicemonitor -A")
        print("      kubectl get svc -n proofline-dev --show-labels")
        print()
        print("  The Service needs app.kubernetes.io/name=proofline.")
        print("  Also give it 60s after deploying -- the first scrape has to happen.")
        return 1

    # 3. are the targets actually up?
    result = get(
        base, "/api/v1/query", {"query": f'up{{job="{args.job}"}}'}
    ).get("data", {}).get("result", [])

    print()
    print(f'  {BOLD}up{{job="{args.job}"}}:{RESET}')
    if not result:
        print(f"      {RED}no targets{RESET}")
        print()
        print("  The job label exists but nothing is being scraped right now.")
        print("  Check the pods are running and the port name matches:")
        print("      kubectl get pods -n proofline-dev")
        print("      kubectl get servicemonitor proofline -n monitoring -o yaml")
        return 1

    down = 0
    for series in result:
        metric = series.get("metric", {})
        value = series.get("value", [None, "0"])[1]
        namespace = metric.get("namespace", "?")
        pod = metric.get("pod", "?")
        if value == "1":
            print(f"      {GREEN}up{RESET}   {namespace}/{pod}")
        else:
            print(f"      {RED}down{RESET} {namespace}/{pod}")
            down += 1

    print()
    if down:
        print(f"  {YELLOW}{down} target(s) down.{RESET}")
        print("  The gate would judge on partial data. Fix this before promoting.")
        return 1

    print(f"  {GREEN}Scraping is healthy. The SLO gate has data to work with.{RESET}")
    print()
    print("  Next:  make prove && make gate      # expect PASS")
    print("         make burn                    # expect BLOCKED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
