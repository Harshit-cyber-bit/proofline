#!/usr/bin/env python3
"""Continuous availability prober.

Runs alongside a deployment, sends a steady stream of requests at the service,
records every result, and exits non-zero if any of them were dropped.

Standard library only, deliberately. This has to run inside a Jenkins agent, a
CI runner, or a scratch container with no package installation step and no
network access to PyPI. A dependency here would be a dependency on the worst
possible day.

    # Probe for the duration of a rollout, then fail the build if anything dropped
    python3 prober/prober.py --url http://localhost:8080/api/work \\
        --duration 90 --interval 0.2 --report /tmp/probe.json

    # Probe until a command finishes, whatever that command is
    python3 prober/prober.py --url http://localhost:8080/api/work \\
        --until-command "kubectl rollout status deploy/proofline -n dev"
"""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, __file__.rsplit("/", 1)[0])

from report import (
    CLASS_CONNECTION,
    CLASS_TIMEOUT,
    Sample,
    summarise,
    verdict,
)


def probe_once(url: str, timeout: float) -> Sample:
    """Send one request and classify whatever comes back."""
    started = time.perf_counter()
    sent_at = time.time()

    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            response.read()
            return Sample(
                sent_at=sent_at,
                latency_ms=(time.perf_counter() - started) * 1000,
                status=response.status,
            )
    except urllib.error.HTTPError as exc:
        # The service answered, just badly. Distinct from nothing answering.
        return Sample(
            sent_at=sent_at,
            latency_ms=(time.perf_counter() - started) * 1000,
            status=exc.code,
            error=str(exc),
        )
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        reason = getattr(exc, "reason", exc)
        is_timeout = isinstance(reason, TimeoutError) or (
            "timed out" in str(reason).lower()
        )
        return Sample(
            sent_at=sent_at,
            latency_ms=(time.perf_counter() - started) * 1000,
            error_class=CLASS_TIMEOUT if is_timeout else CLASS_CONNECTION,
            error=str(reason),
        )


def run(
    url: str,
    duration: float | None,
    interval: float,
    timeout: float,
    stop: threading.Event,
) -> list[Sample]:
    """Probe at a fixed rate until the duration elapses or stop is set.

    Requests are dispatched to a small thread pool rather than being sent
    inline, so that a request which hangs for the full timeout does not stall
    the schedule behind it. A prober whose own rate collapses during an outage
    under-reports exactly the event it exists to measure.
    """
    samples: list[Sample] = []
    lock = threading.Lock()
    deadline = time.monotonic() + duration if duration else None

    def record(future_result: Sample) -> None:
        with lock:
            samples.append(future_result)

    with ThreadPoolExecutor(max_workers=16) as pool:
        futures = []
        next_send = time.monotonic()

        while not stop.is_set():
            if deadline and time.monotonic() >= deadline:
                break

            futures.append(pool.submit(lambda: record(probe_once(url, timeout))))

            next_send += interval
            sleep_for = next_send - time.monotonic()
            if sleep_for > 0:
                stop.wait(sleep_for)
            else:
                # Falling behind schedule; reset rather than accumulating debt.
                next_send = time.monotonic()

        for future in futures:
            future.result()

    samples.sort(key=lambda s: s.sent_at)
    return samples


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="URL to probe")
    parser.add_argument(
        "--duration",
        type=float,
        help="probe for this many seconds (omit with --until-command)",
    )
    parser.add_argument(
        "--until-command",
        help="probe until this shell command exits; its exit code is honoured",
    )
    parser.add_argument(
        "--interval", type=float, default=0.2, help="seconds between requests"
    )
    parser.add_argument(
        "--timeout", type=float, default=5.0, help="per-request timeout"
    )
    parser.add_argument("--report", help="write the JSON report here")
    parser.add_argument(
        "--max-failures",
        type=int,
        default=0,
        help="tolerated failed requests before the run fails (default 0)",
    )
    parser.add_argument(
        "--min-availability",
        type=float,
        default=None,
        help=(
            "optional availability floor as a percentage; unset by default so "
            "that --max-failures is the single tolerance control"
        ),
    )
    parser.add_argument(
        "--min-samples",
        type=int,
        default=30,
        help="fail if fewer probes than this were recorded (default 30)",
    )
    parser.add_argument(
        "--max-latency-p99", type=float, help="fail above this p99 in ms"
    )
    args = parser.parse_args()

    if not args.duration and not args.until_command:
        parser.error("one of --duration or --until-command is required")

    stop = threading.Event()
    command_result: dict[str, int] = {}

    if args.until_command:
        def run_command() -> None:
            try:
                completed = subprocess.run(
                    shlex.split(args.until_command), check=False
                )
                command_result["code"] = completed.returncode
            finally:
                # Keep probing briefly after the command returns. `kubectl
                # rollout status` returns when the *last* pod is ready, which is
                # before the old pods have finished terminating -- and that tail
                # is precisely where dropped requests hide.
                time.sleep(10)
                stop.set()

        thread = threading.Thread(target=run_command, daemon=True)
        thread.start()

    print(f"probing {args.url} every {args.interval}s", file=sys.stderr)
    samples = run(args.url, args.duration, args.interval, args.timeout, stop)

    report = summarise(samples, interval_seconds=args.interval)
    result = verdict(
        report,
        max_failures=args.max_failures,
        min_availability_pct=args.min_availability,
        min_samples=args.min_samples,
        max_latency_p99_ms=args.max_latency_p99,
    )

    payload = {
        "url": args.url,
        "report": report.as_dict(),
        "verdict": result.as_dict(),
    }

    if args.report:
        with open(args.report, "w") as handle:
            json.dump(payload, handle, indent=2)

    print(json.dumps(payload, indent=2))

    print(file=sys.stderr)
    if result.passed:
        print(
            f"PASS  {report.total} requests, {report.availability_pct}% available, "
            f"p99 {report.latency_p99_ms}ms",
            file=sys.stderr,
        )
    else:
        print(
            f"FAIL  {report.total} requests, {report.failed} dropped",
            file=sys.stderr,
        )
        for reason in result.reasons:
            print(f"      - {reason}", file=sys.stderr)

    if not result.passed:
        return 1
    # A green probe still must not mask the deployment itself having failed.
    return command_result.get("code", 0)


if __name__ == "__main__":
    raise SystemExit(main())
