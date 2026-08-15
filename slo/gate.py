#!/usr/bin/env python3
"""The promotion gate.

After a deploy lands, the pipeline asks Prometheus one question: did what I just
shipped make this environment worse? If the answer is yes, or if there is not
enough traffic to know, the build does not promote to the next environment.

Standard library only, for the same reason as the prober: this runs on a Jenkins
agent, and a gate that needs `pip install` to work is a gate that stops working
the day the agent loses network access to PyPI.

    python3 slo/gate.py --prometheus http://localhost:30090 --environment dev
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field

__all__ = ["GateResult", "evaluate", "query_prometheus"]


@dataclass
class GateResult:
    """Whether this deployment earned its promotion."""

    passed: bool
    error_ratio: float | None = None
    total_requests: float | None = None
    reasons: list[str] = field(default_factory=list)
    checks: dict[str, str] = field(default_factory=dict)

    def as_dict(self) -> dict:
        return asdict(self)


def evaluate(
    error_ratio: float | None,
    total_requests: float | None,
    max_error_ratio: float,
    min_requests: float,
) -> GateResult:
    """Decide whether to promote, from two numbers and two thresholds.

    Pure, so the decision is unit tested rather than discovered in a pipeline
    run at 6pm on a Friday.

    The three ways this returns False are, in order of how often they matter:

    1.  The error ratio exceeds the threshold. The obvious one.
    2.  There was not enough traffic to tell. A gate that passes on silence is
        decoration -- the most common way a "we have SLO gates" claim turns out
        to be untrue is that the query returns nothing and nothing checks.
    3.  Prometheus returned no data at all, which usually means the scrape is
        broken, the job label is wrong, or the deploy never became ready. All
        three are reasons not to promote.
    """
    reasons: list[str] = []
    checks: dict[str, str] = {}

    if total_requests is None or error_ratio is None:
        return GateResult(
            passed=False,
            error_ratio=error_ratio,
            total_requests=total_requests,
            reasons=[
                "prometheus returned no data for this environment; the scrape "
                "may be broken, the job label wrong, or the deployment never "
                "became ready. Not promoting on an unanswered question."
            ],
            checks={"data": "absent"},
        )

    if total_requests < min_requests:
        reasons.append(
            f"only {total_requests:.0f} request(s) observed, need at least "
            f"{min_requests:.0f}; not enough traffic to judge this deployment"
        )
        checks["traffic"] = "insufficient"
    else:
        checks["traffic"] = "ok"

    if error_ratio > max_error_ratio:
        reasons.append(
            f"error ratio {error_ratio:.4%} exceeds the promotion threshold "
            f"{max_error_ratio:.4%}"
        )
        checks["errors"] = "over-threshold"
    else:
        checks["errors"] = "ok"

    return GateResult(
        passed=not reasons,
        error_ratio=error_ratio,
        total_requests=total_requests,
        reasons=reasons,
        checks=checks,
    )


def query_prometheus(base_url: str, query: str, timeout: float = 15.0) -> float | None:
    """Run an instant query and return the single scalar it produced.

    Returns None rather than raising when the query yields nothing, because
    "no data" is a normal and meaningful answer here -- and one the gate treats
    as a failure rather than a pass.
    """
    url = f"{base_url.rstrip('/')}/api/v1/query?" + urllib.parse.urlencode(
        {"query": query}
    )

    with urllib.request.urlopen(url, timeout=timeout) as response:
        payload = json.loads(response.read())

    if payload.get("status") != "success":
        raise RuntimeError(f"prometheus query failed: {payload.get('error')}")

    result = payload.get("data", {}).get("result", [])
    if not result:
        return None

    value = float(result[0]["value"][1])
    # A ratio with no denominator comes back as NaN. Treating NaN as a number
    # would make `NaN > threshold` evaluate False and quietly pass the gate.
    if value != value:
        return None
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prometheus", required=True, help="Prometheus base URL")
    parser.add_argument("--environment", required=True, help="environment to judge")
    parser.add_argument("--job", default="proofline", help="Prometheus job label")
    parser.add_argument("--window", default="10m", help="evaluation window")
    parser.add_argument(
        "--max-error-ratio",
        type=float,
        default=0.01,
        help="maximum tolerated error ratio (default 0.01 = 1%%)",
    )
    parser.add_argument(
        "--min-requests",
        type=float,
        default=100,
        help="minimum requests required to form a judgement",
    )
    parser.add_argument("--report", help="write the JSON result here")
    args = parser.parse_args()

    selector = f'job="{args.job}",namespace="proofline-{args.environment}"'

    total_query = f"sum(increase(http_requests_total{{{selector}}}[{args.window}]))"
    error_query = (
        f'sum(increase(http_requests_total{{{selector},status=~"5.."}}'
        f"[{args.window}]))"
    )

    try:
        total = query_prometheus(args.prometheus, total_query)
        errors = query_prometheus(args.prometheus, error_query)
    except Exception as exc:
        print(f"gate: cannot reach prometheus: {exc}", file=sys.stderr)
        return 1

    # No error series at all means no errors, provided there was traffic.
    ratio = None if total is None or total == 0 else (errors or 0.0) / total

    result = evaluate(ratio, total, args.max_error_ratio, args.min_requests)

    payload = {
        "environment": args.environment,
        "window": args.window,
        "queries": {"total": total_query, "errors": error_query},
        "result": result.as_dict(),
    }

    if args.report:
        with open(args.report, "w") as handle:
            json.dump(payload, handle, indent=2)

    print(json.dumps(payload, indent=2))

    print(file=sys.stderr)
    if result.passed:
        print(
            f"PASS  {args.environment}: {result.total_requests:.0f} requests, "
            f"{result.error_ratio:.4%} errors",
            file=sys.stderr,
        )
        return 0

    print(f"BLOCKED  {args.environment} did not earn promotion", file=sys.stderr)
    for reason in result.reasons:
        print(f"         - {reason}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
