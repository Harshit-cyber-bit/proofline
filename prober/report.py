"""Turning a stream of probe samples into a verdict.

This module is the reason the repo exists. "Zero-downtime deployment" is a claim
that appears on almost every SRE CV, including mine, and almost nobody measures
it. Here it is a test: the prober records every request sent during a rollout,
this module decides whether any of them were dropped, and the pipeline fails if
they were.

Kept as pure functions over a list of samples so the interesting decisions --
what counts as downtime, how to estimate its duration, when to fail a build --
are unit tested rather than trusted.
"""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass, field
from typing import Any

__all__ = ["Report", "Sample", "Verdict", "summarise", "verdict"]

# Failure classes, kept coarse. The distinction that matters operationally is
# "the service answered badly" (5xx) versus "nothing answered at all"
# (connection refused, reset, timeout) -- the second is what a bad rollout looks
# like, because the pod left the endpoint list while requests were still coming.
CLASS_SERVER_ERROR = "server_error"
CLASS_CONNECTION = "connection_error"
CLASS_TIMEOUT = "timeout"
CLASS_CLIENT_ERROR = "client_error"


@dataclass
class Sample:
    """One request the prober sent."""

    sent_at: float
    latency_ms: float
    status: int | None = None
    error_class: str | None = None
    error: str | None = None

    @property
    def ok(self) -> bool:
        return (
            self.error_class is None
            and self.status is not None
            and self.status < 500
        )


@dataclass
class Report:
    """What happened during the probe window."""

    total: int = 0
    succeeded: int = 0
    failed: int = 0
    availability_pct: float = 100.0
    failures_by_class: dict[str, int] = field(default_factory=dict)
    max_consecutive_failures: int = 0
    estimated_downtime_seconds: float = 0.0
    first_failure_at: float | None = None
    latency_p50_ms: float = 0.0
    latency_p95_ms: float = 0.0
    latency_p99_ms: float = 0.0
    latency_max_ms: float = 0.0
    interval_seconds: float = 0.0

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class Verdict:
    """Whether the rollout passed, and why not if it did not."""

    passed: bool
    reasons: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


def _percentile(values: list[float], pct: float) -> float:
    """Nearest-rank percentile: the smallest value at or above pct of the data.

    Deliberately not interpolating. With a few hundred samples, interpolation
    invents a latency figure that no request actually experienced, and that
    number ends up in a report someone quotes.
    """
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = math.ceil(pct / 100.0 * len(ordered))
    rank = max(1, min(len(ordered), rank))
    return ordered[rank - 1]


def summarise(samples: list[Sample], interval_seconds: float = 0.0) -> Report:
    """Reduce raw samples to a report.

    Args:
        samples: Every request the prober sent, in the order it sent them.
        interval_seconds: The probe interval, used to turn a run of consecutive
            failures into an estimate of how long the service was actually down.
    """
    report = Report(interval_seconds=interval_seconds)
    if not samples:
        return report

    report.total = len(samples)

    consecutive = 0
    latencies: list[float] = []

    for sample in samples:
        if sample.ok:
            report.succeeded += 1
            consecutive = 0
            # Only successful requests contribute latency. A connection refused
            # in 0.2ms is not a fast request, and letting it into the
            # distribution would make an outage look like a performance win.
            latencies.append(sample.latency_ms)
            continue

        report.failed += 1
        consecutive += 1
        report.max_consecutive_failures = max(
            report.max_consecutive_failures, consecutive
        )
        if report.first_failure_at is None:
            report.first_failure_at = sample.sent_at

        cls = sample.error_class or _class_for_status(sample.status)
        report.failures_by_class[cls] = report.failures_by_class.get(cls, 0) + 1

    report.availability_pct = round(100.0 * report.succeeded / report.total, 4)
    report.estimated_downtime_seconds = round(
        report.max_consecutive_failures * interval_seconds, 3
    )

    report.latency_p50_ms = round(_percentile(latencies, 50), 2)
    report.latency_p95_ms = round(_percentile(latencies, 95), 2)
    report.latency_p99_ms = round(_percentile(latencies, 99), 2)
    report.latency_max_ms = round(max(latencies), 2) if latencies else 0.0

    return report


def _class_for_status(status: int | None) -> str:
    if status is None:
        return CLASS_CONNECTION
    if status >= 500:
        return CLASS_SERVER_ERROR
    return CLASS_CLIENT_ERROR


def verdict(
    report: Report,
    max_failures: int = 0,
    min_availability_pct: float | None = None,
    min_samples: int = 30,
    max_latency_p99_ms: float | None = None,
) -> Verdict:
    """Decide whether this rollout passes.

    The default is strict -- a single dropped request fails the build. That is
    the point: "zero-downtime" either means zero or it means nothing. Real
    deployments that genuinely cannot meet it should raise ``max_failures``
    explicitly and visibly, rather than quietly measuring nothing.

    ``min_availability_pct`` is an *additional*, optional gate for services that
    reason in percentages rather than absolute counts. It defaults to unset so
    that raising ``max_failures`` actually raises the tolerance -- an
    availability floor left at 100% would silently override it, which is the
    kind of contradiction that makes people stop trusting a gate.

    ``min_samples`` guards against the failure mode that makes this whole check
    worthless: a prober that never started, or died early, reports 100%
    availability across two requests and waves a broken rollout through. Too few
    samples is treated as a failure, not a pass.
    """
    reasons: list[str] = []

    if report.total < min_samples:
        reasons.append(
            f"only {report.total} probe(s) recorded, need at least {min_samples}; "
            "the prober did not run long enough to prove anything"
        )

    if report.failed > max_failures:
        detail = ", ".join(
            f"{count} {cls}" for cls, count in sorted(report.failures_by_class.items())
        )
        reasons.append(
            f"{report.failed} request(s) failed (allowed {max_failures}): {detail}"
        )

    if (
        min_availability_pct is not None
        and report.availability_pct < min_availability_pct
    ):
        reasons.append(
            f"availability {report.availability_pct}% "
            f"below threshold {min_availability_pct}%"
        )

    if report.max_consecutive_failures > 1:
        reasons.append(
            f"{report.max_consecutive_failures} consecutive failures "
            f"(~{report.estimated_downtime_seconds}s of downtime), which means "
            "traffic was being dropped, not just an isolated error"
        )

    if max_latency_p99_ms is not None and report.latency_p99_ms > max_latency_p99_ms:
        reasons.append(
            f"p99 latency {report.latency_p99_ms}ms exceeded "
            f"{max_latency_p99_ms}ms"
        )

    return Verdict(passed=not reasons, reasons=reasons)
