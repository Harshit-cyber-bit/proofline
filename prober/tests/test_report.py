"""Tests for the probe analysis.

The verdict these produce is what fails a deployment, so the edge cases matter
more than the happy path: a prober that died early, an outage split across
retries, a connection refused that looks fast.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from report import (
    CLASS_CONNECTION,
    CLASS_SERVER_ERROR,
    CLASS_TIMEOUT,
    Sample,
    summarise,
    verdict,
)


def ok(n=1, latency=10.0):
    return [
        Sample(sent_at=float(i), latency_ms=latency, status=200) for i in range(n)
    ]


def refused(n=1, start=0):
    return [
        Sample(
            sent_at=float(start + i),
            latency_ms=0.3,
            error_class=CLASS_CONNECTION,
            error="Connection refused",
        )
        for i in range(n)
    ]


def server_error(n=1, start=0):
    return [
        Sample(sent_at=float(start + i), latency_ms=8.0, status=503) for i in range(n)
    ]


# ----------------------------------------------------------------- summarise


def test_an_empty_run_summarises_without_crashing():
    report = summarise([])
    assert report.total == 0
    assert report.availability_pct == 100.0


def test_a_clean_run_is_fully_available():
    report = summarise(ok(100), interval_seconds=0.2)
    assert report.total == 100
    assert report.failed == 0
    assert report.availability_pct == 100.0
    assert report.failures_by_class == {}


def test_failures_are_counted_and_classified():
    report = summarise(ok(90) + refused(5) + server_error(5), interval_seconds=0.2)
    assert report.failed == 10
    assert report.availability_pct == 90.0
    assert report.failures_by_class == {CLASS_CONNECTION: 5, CLASS_SERVER_ERROR: 5}


def test_a_status_5xx_counts_as_a_failure_but_4xx_does_not():
    # A 404 means the prober asked for the wrong thing, not that the service is
    # down. Counting it would make every misconfigured probe look like an outage.
    samples = [
        Sample(sent_at=0, latency_ms=5, status=404),
        Sample(sent_at=1, latency_ms=5, status=500),
    ]
    report = summarise(samples)
    assert report.failed == 1
    assert report.failures_by_class == {CLASS_SERVER_ERROR: 1}


def test_consecutive_failures_are_tracked_not_just_totals():
    # Ten scattered failures and ten in a row are very different events.
    scattered = []
    for i in range(10):
        scattered.extend(ok(9))
        scattered.extend(refused(1, start=i))

    contiguous = ok(45) + refused(10, start=100) + ok(45)

    assert summarise(scattered).max_consecutive_failures == 1
    assert summarise(contiguous).max_consecutive_failures == 10


def test_downtime_is_estimated_from_the_longest_outage_and_the_interval():
    report = summarise(ok(50) + refused(15) + ok(50), interval_seconds=0.2)
    assert report.max_consecutive_failures == 15
    assert report.estimated_downtime_seconds == pytest.approx(3.0)


def test_the_first_failure_timestamp_is_recorded():
    samples = ok(5) + refused(1, start=99)
    assert summarise(samples).first_failure_at == 99.0


def test_failed_requests_do_not_pollute_the_latency_distribution():
    # A connection refused returns in a fraction of a millisecond. If it counted
    # as a sample, an outage would show up as a latency improvement.
    report = summarise(ok(10, latency=100.0) + refused(90), interval_seconds=0.1)
    assert report.latency_p50_ms == 100.0
    assert report.latency_max_ms == 100.0


def test_percentiles_are_nearest_rank_not_interpolated():
    samples = [
        Sample(sent_at=i, latency_ms=float(i + 1), status=200) for i in range(100)
    ]
    report = summarise(samples)
    assert report.latency_p50_ms == 50.0
    assert report.latency_p95_ms == 95.0
    assert report.latency_p99_ms == 99.0
    assert report.latency_max_ms == 100.0


def test_latency_of_a_single_sample_is_that_sample():
    report = summarise(ok(1, latency=42.0))
    assert report.latency_p50_ms == 42.0
    assert report.latency_p99_ms == 42.0


# -------------------------------------------------------------------- verdict


def test_a_clean_run_passes():
    result = verdict(summarise(ok(100), interval_seconds=0.2))
    assert result.passed
    assert result.reasons == []


def test_a_single_dropped_request_fails_by_default():
    # This is the whole point. Zero-downtime means zero.
    result = verdict(summarise(ok(199) + refused(1), interval_seconds=0.2))
    assert not result.passed
    assert any("1 request(s) failed" in r for r in result.reasons)


def test_a_tolerance_can_be_set_explicitly():
    result = verdict(
        summarise(ok(199) + refused(1), interval_seconds=0.2), max_failures=1
    )
    assert result.passed


def test_consecutive_failures_fail_even_within_the_tolerance():
    # Five failures might be within budget as isolated errors, but five in a row
    # is traffic hitting the floor, and it should never pass silently.
    result = verdict(
        summarise(ok(95) + refused(5), interval_seconds=0.2), max_failures=10
    )
    assert not result.passed
    assert any("consecutive failures" in r for r in result.reasons)


def test_a_prober_that_barely_ran_fails_rather_than_passing_vacuously():
    # The dangerous failure mode: prober crashes after two requests, reports
    # 100% availability, and waves a broken rollout through.
    result = verdict(summarise(ok(2), interval_seconds=0.2))
    assert not result.passed
    assert any("did not run long enough" in r for r in result.reasons)


def test_the_minimum_sample_count_is_configurable():
    result = verdict(summarise(ok(2), interval_seconds=0.2), min_samples=1)
    assert result.passed


def test_an_availability_threshold_can_be_applied():
    report = summarise(ok(90) + refused(10), interval_seconds=0.2)
    result = verdict(report, max_failures=100, min_availability_pct=95.0)
    assert not result.passed
    assert any("availability" in r for r in result.reasons)


def test_a_latency_ceiling_can_fail_an_otherwise_clean_run():
    report = summarise(ok(100, latency=500.0), interval_seconds=0.2)
    assert verdict(report).passed
    result = verdict(report, max_latency_p99_ms=250.0)
    assert not result.passed
    assert any("p99 latency" in r for r in result.reasons)


def test_every_failure_reason_is_reported_not_just_the_first():
    report = summarise(ok(10) + refused(10), interval_seconds=0.2)
    result = verdict(report, min_availability_pct=99.0, min_samples=100)
    assert len(result.reasons) >= 3


def test_timeouts_are_distinguished_from_refusals():
    samples = [
        *ok(10),
        Sample(
            sent_at=99,
            latency_ms=5000,
            error_class=CLASS_TIMEOUT,
            error="timed out",
        ),
    ]
    report = summarise(samples)
    assert report.failures_by_class == {CLASS_TIMEOUT: 1}
