#!/usr/bin/env python3
"""The promotion gate.

After a deploy lands, the pipeline asks Prometheus one question: did what I just
shipped make this environment worse? If the answer is yes, or if there is not
enough traffic to know, the build does not promote to the next environment.

Standard library only, for the same reason as the prober: this runs on a Jenkins
agent, and a gate that needs `pip install` to work is a gate that stops working
the day the agent loses network access to PyPI.

    python3 slo/gate.py --prometheus http://localhost:30090 --environment dev

Two design decisions here were bought with a failure, and both are the kind of
thing that makes a gate decorative rather than load-bearing.

**Two windows, not one.** The first version averaged over ten minutes. A
two-minute deploy serving 20% errors averages out to well under the 1%
threshold, so the gate promoted a release the prober had just failed and the
alert rules would have paged for. The alert rules in slo/rules/ have always
paired a long window with a short one, for exactly this reason; the gate did
not, and the two disagreed about the same incident. It now asks both: is the
budget spent over the deploy window, *and* is it burning right now.

**Health-check traffic is not user traffic.** A readiness probe every two
seconds against two pods is a steady stream of guaranteed-200s. Counted in the
SLI it does nothing but dilute real errors -- and it dilutes them hardest
exactly when the service is small and struggling. Probe and metrics endpoints
are excluded from both the gate and the recorded SLIs.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field

__all__ = [
    "EXCLUDED_PATHS",
    "GateResult",
    "count_query",
    "evaluate",
    "query_prometheus",
    "ratio_query",
    "selector",
]

# Endpoints that exist for the cluster, not for users. See the module docstring.
EXCLUDED_PATHS = ("/healthz", "/readyz", "/metrics")


@dataclass
class GateResult:
    """Whether this deployment earned its promotion."""

    passed: bool
    error_ratio: float | None = None
    total_requests: float | None = None
    short_error_ratio: float | None = None
    short_total_requests: float | None = None
    reasons: list[str] = field(default_factory=list)
    checks: dict[str, str] = field(default_factory=dict)

    def as_dict(self) -> dict:
        return asdict(self)


def evaluate(
    error_ratio: float | None,
    total_requests: float | None,
    max_error_ratio: float,
    min_requests: float,
    short_error_ratio: float | None = None,
    short_total_requests: float | None = None,
    min_short_requests: float = 0.0,
    short_window: str = "",
) -> GateResult:
    """Decide whether to promote, from four numbers and three thresholds.

    Pure, so the decision is unit tested rather than discovered in a pipeline
    run at 6pm on a Friday.

    The ways this returns False, in order of how often they matter:

    1.  The error ratio over the deploy window exceeds the threshold. The
        obvious one.
    2.  The error ratio over the *short* window exceeds it, even though the
        long window looks fine. This is a regression that started recently and
        has not yet moved the average -- the case the single-window version of
        this gate promoted straight through.
    3.  There was not enough traffic to tell. A gate that passes on silence is
        decoration -- the most common way a "we have SLO gates" claim turns out
        to be untrue is that the query returns nothing and nothing checks.
    4.  Prometheus returned no data at all, which usually means the scrape is
        broken, the job label is wrong, or the deploy never became ready. All
        three are reasons not to promote.

    The short window deliberately does *not* block when it is quiet. Traffic
    stopping is not evidence of a bad deploy, and the long-window traffic floor
    already closes the pass-on-silence hole. It is reported, so a reviewer can
    see the gate judged on older data than they might assume.
    """
    reasons: list[str] = []
    checks: dict[str, str] = {}

    if total_requests is None or error_ratio is None:
        return GateResult(
            passed=False,
            error_ratio=error_ratio,
            total_requests=total_requests,
            short_error_ratio=short_error_ratio,
            short_total_requests=short_total_requests,
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

    if short_window:
        if short_error_ratio is None or short_total_requests is None:
            checks["recent"] = "no traffic"
        elif short_total_requests < min_short_requests:
            checks["recent"] = "insufficient"
        elif short_error_ratio > max_error_ratio:
            reasons.append(
                f"error ratio over the last {short_window} is "
                f"{short_error_ratio:.4%}, over the {max_error_ratio:.4%} "
                f"threshold; errors are being served right now even if the "
                f"longer window has not caught up"
            )
            checks["recent"] = "over-threshold"
        else:
            checks["recent"] = "ok"

    return GateResult(
        passed=not reasons,
        error_ratio=error_ratio,
        total_requests=total_requests,
        short_error_ratio=short_error_ratio,
        short_total_requests=short_total_requests,
        reasons=reasons,
        checks=checks,
    )


def selector(job: str, environment: str, exclude_paths: tuple[str, ...]) -> str:
    """The label selector shared by every query the gate runs."""
    parts = [f'job="{job}"', f'namespace="proofline-{environment}"']
    if exclude_paths:
        parts.append(f'path!~"{"|".join(exclude_paths)}"')
    return ",".join(parts)


def ratio_query(sel: str, window: str) -> str:
    """Error ratio, computed by Prometheus rather than by dividing in Python.

    Two subtleties, both of which produced a wrong answer before they were
    handled.

    `or vector(0)` is load-bearing. When there have been no errors at all, the
    numerator matches no series, and an empty vector divided by anything is
    empty -- so a perfectly healthy deployment came back as "no data" and got
    blocked. `or vector(0)` turns "no error series" into the zero it means.

    Dividing inside Prometheus, rather than fetching two counts and dividing
    here, keeps numerator and denominator on the same window with the same
    extrapolation. Two separate `increase()` queries do not agree with each
    other when series come and go mid-window -- which, with a rollout in
    progress, they always do.
    """
    return (
        f'(sum(rate(http_requests_total{{{sel},status=~"5.."}}[{window}]))'
        f" or vector(0))"
        f" / sum(rate(http_requests_total{{{sel}}}[{window}]))"
    )


def count_query(sel: str, window: str) -> str:
    """Requests in the window, for the traffic floor only.

    Extrapolated, so treat it as an order of magnitude rather than a count. It
    decides "was anyone using this", not "how healthy is it".

    How far off it is, measured rather than assumed: on a 10m window during a
    run with two rollouts in it, this reported 3,169 requests to /readyz where
    the probe schedule allows at most ~600, and 463 scrapes of /metrics where
    the scrape interval allows ~80. Both inflated by the same factor of five to
    six. `increase()` extrapolates each series across the full window, and a
    rollout replaces every pod, so the window fills with short-lived series each
    of which gets stretched to ten minutes.

    This is the argument for computing the ratio inside Prometheus (see
    ratio_query): the numerator and denominator inflate together and the ratio
    survives, while any absolute count taken from the same data does not. The
    evidence that it works is that the gate's ratio agreed with the prober --
    22.36% against the prober's 21.4% over the same two minutes -- while these
    counts were off by 5x.
    """
    return f"sum(increase(http_requests_total{{{sel}}}[{window}]))"


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


def query_breakdown(base_url: str, query: str, timeout: float = 15.0) -> list[tuple]:
    """Run an instant query that returns many series, for --explain."""
    url = f"{base_url.rstrip('/')}/api/v1/query?" + urllib.parse.urlencode(
        {"query": query}
    )
    with urllib.request.urlopen(url, timeout=timeout) as response:
        payload = json.loads(response.read())

    rows = []
    for series in payload.get("data", {}).get("result", []):
        metric = series.get("metric", {})
        value = float(series.get("value", [0, "0"])[1])
        if value != value:
            continue
        rows.append((metric.get("path", "?"), metric.get("status", "?"), value))
    return sorted(rows, key=lambda row: -row[2])


def explain(base_url: str, job: str, environment: str, window: str) -> None:
    """Print where the traffic actually is, when the gate and the prober differ.

    The gate saying PASS while the prober says FAIL means one of them is
    measuring the wrong thing. This shows the denominator broken down by path,
    which is usually enough to see it: a wall of /readyz means health checks are
    being counted as user traffic, and the real errors have been diluted into
    the noise floor.
    """
    sel_all = f'job="{job}",namespace="proofline-{environment}"'
    breakdown = (
        f"sum by (path,status) "
        f"(increase(http_requests_total{{{sel_all}}}[{window}]))"
    )
    rows = query_breakdown(base_url, breakdown)

    if not rows:
        print(f"  no series at all over {window}", file=sys.stderr)
        return

    total = sum(row[2] for row in rows)
    counted = sum(row[2] for row in rows if row[0] not in EXCLUDED_PATHS)

    print(f"  requests by path over {window} (extrapolated):", file=sys.stderr)
    for path, status, value in rows:
        excluded = "  excluded from the SLI" if path in EXCLUDED_PATHS else ""
        print(f"      {value:12,.0f}  {status:>4}  {path}{excluded}", file=sys.stderr)

    print(file=sys.stderr)
    print(
        f"      {total:12,.0f}  total, of which {counted:,.0f} is user traffic",
        file=sys.stderr,
    )
    if total and counted / total < 0.5:
        share = 100 * (1 - counted / total)
        dilution = total / max(counted, 1)
        print(
            f"      {share:.0f}% of it is health checks and metrics scrapes.",
            file=sys.stderr,
        )
        print(
            f"      Counting those in the SLI divides every real error by "
            f"{dilution:.0f}.",
            file=sys.stderr,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prometheus", required=True, help="Prometheus base URL")
    parser.add_argument("--environment", required=True, help="environment to judge")
    parser.add_argument("--job", default="proofline", help="Prometheus job label")
    parser.add_argument("--window", default="10m", help="the deploy window")
    parser.add_argument(
        "--short-window",
        default="2m",
        help="the is-it-burning-now window; empty string disables it",
    )
    parser.add_argument(
        "--max-error-ratio",
        type=float,
        default=0.01,
        help="maximum tolerated error ratio, on either window (default 0.01 = 1%%)",
    )
    parser.add_argument(
        "--min-requests",
        type=float,
        default=100,
        help="minimum requests required to form a judgement",
    )
    parser.add_argument(
        "--include-probe-paths",
        action="store_true",
        help="count /healthz, /readyz and /metrics as user traffic (they are not)",
    )
    parser.add_argument(
        "--explain",
        action="store_true",
        help="print the traffic breakdown, for when this disagrees with the prober",
    )
    parser.add_argument("--report", help="write the JSON result here")
    args = parser.parse_args()

    excluded = () if args.include_probe_paths else EXCLUDED_PATHS
    sel = selector(args.job, args.environment, excluded)

    queries = {
        "ratio": ratio_query(sel, args.window),
        "total": count_query(sel, args.window),
    }
    if args.short_window:
        queries["ratio_short"] = ratio_query(sel, args.short_window)
        queries["total_short"] = count_query(sel, args.short_window)

    try:
        values = {
            name: query_prometheus(args.prometheus, query)
            for name, query in queries.items()
        }
    except Exception as exc:
        print(f"gate: cannot reach prometheus: {exc}", file=sys.stderr)
        return 1

    # The short window is a fraction of the long one, so its traffic floor is
    # the same fraction of the long one's. Derived rather than configured, so
    # the two cannot drift apart.
    min_short = args.min_requests * _window_seconds(args.short_window) / max(
        _window_seconds(args.window), 1
    )

    result = evaluate(
        values["ratio"],
        values["total"],
        args.max_error_ratio,
        args.min_requests,
        short_error_ratio=values.get("ratio_short"),
        short_total_requests=values.get("total_short"),
        min_short_requests=min_short,
        short_window=args.short_window,
    )

    payload = {
        "environment": args.environment,
        "window": args.window,
        "short_window": args.short_window,
        "excluded_paths": list(excluded),
        "queries": queries,
        "result": result.as_dict(),
    }

    if args.report:
        with open(args.report, "w") as handle:
            json.dump(payload, handle, indent=2)

    print(json.dumps(payload, indent=2))

    print(file=sys.stderr)
    if result.passed:
        recent = ""
        if result.short_error_ratio is not None:
            recent = (
                f", {result.short_error_ratio:.4%} "
                f"over the last {args.short_window}"
            )
        print(
            f"PASS  {args.environment}: {result.total_requests:.0f} requests, "
            f"{result.error_ratio:.4%} errors{recent}",
            file=sys.stderr,
        )
        if args.explain:
            print(file=sys.stderr)
            explain(args.prometheus, args.job, args.environment, args.window)
        return 0

    print(f"BLOCKED  {args.environment} did not earn promotion", file=sys.stderr)
    for reason in result.reasons:
        print(f"         - {reason}", file=sys.stderr)
    if args.explain:
        print(file=sys.stderr)
        explain(args.prometheus, args.job, args.environment, args.window)
    return 1


def _window_seconds(window: str) -> float:
    """Parse a Prometheus duration well enough for the windows a gate uses."""
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    if not window or window[-1] not in units:
        return 0.0
    try:
        return float(window[:-1]) * units[window[-1]]
    except ValueError:
        return 0.0


if __name__ == "__main__":
    raise SystemExit(main())
