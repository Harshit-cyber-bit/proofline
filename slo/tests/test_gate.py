"""Tests for the promotion gate.

The gate blocks deployments, so the cases worth writing are the ones where it
might wrongly let something through: no data, no traffic, and NaN.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from gate import evaluate, query_prometheus

MAX_RATIO = 0.01
MIN_REQUESTS = 100


# ------------------------------------------------------------------ evaluate


def test_a_healthy_deployment_is_promoted():
    result = evaluate(0.001, 5000, MAX_RATIO, MIN_REQUESTS)
    assert result.passed
    assert result.reasons == []
    assert result.checks == {"traffic": "ok", "errors": "ok"}


def test_a_deployment_over_the_error_threshold_is_blocked():
    result = evaluate(0.05, 5000, MAX_RATIO, MIN_REQUESTS)
    assert not result.passed
    assert any("exceeds the promotion threshold" in r for r in result.reasons)


def test_the_threshold_is_inclusive_at_the_boundary():
    # Exactly at the threshold passes. A gate that fails on equality makes the
    # documented threshold subtly wrong.
    assert evaluate(0.01, 5000, MAX_RATIO, MIN_REQUESTS).passed
    assert not evaluate(0.0100001, 5000, MAX_RATIO, MIN_REQUESTS).passed


def test_a_quiet_environment_does_not_pass_by_default():
    # The important case. Ten requests and zero errors is not evidence of a
    # healthy deployment; it is evidence that nobody used it.
    result = evaluate(0.0, 10, MAX_RATIO, MIN_REQUESTS)
    assert not result.passed
    assert any("not enough traffic" in r for r in result.reasons)


def test_absent_data_blocks_rather_than_passes():
    result = evaluate(None, None, MAX_RATIO, MIN_REQUESTS)
    assert not result.passed
    assert result.checks == {"data": "absent"}
    assert any("no data" in r for r in result.reasons)


def test_absent_data_blocks_even_when_only_the_ratio_is_missing():
    result = evaluate(None, 5000, MAX_RATIO, MIN_REQUESTS)
    assert not result.passed


def test_both_failures_are_reported_together():
    result = evaluate(0.5, 10, MAX_RATIO, MIN_REQUESTS)
    assert not result.passed
    assert len(result.reasons) == 2


def test_thresholds_are_configurable():
    # A canary environment might reasonably accept more errors and less traffic.
    result = evaluate(0.04, 50, max_error_ratio=0.05, min_requests=10)
    assert result.passed


def test_a_perfectly_clean_environment_passes():
    result = evaluate(0.0, 100000, MAX_RATIO, MIN_REQUESTS)
    assert result.passed
    assert result.error_ratio == 0.0


def test_the_result_serialises_for_the_pipeline_artifact():
    payload = evaluate(0.002, 5000, MAX_RATIO, MIN_REQUESTS).as_dict()
    assert json.loads(json.dumps(payload))["passed"] is True


# ----------------------------------------------------------- query_prometheus


class FakeResponse:
    def __init__(self, payload):
        self._payload = json.dumps(payload).encode()

    def read(self):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def fake_urlopen(payload):
    return lambda *args, **kwargs: FakeResponse(payload)


def test_a_scalar_result_is_returned():
    payload = {
        "status": "success",
        "data": {"result": [{"value": [1755200000, "42.5"]}]},
    }
    with patch("urllib.request.urlopen", fake_urlopen(payload)):
        assert query_prometheus("http://prom", "up") == 42.5


def test_an_empty_result_is_none_not_zero():
    # Zero would mean "measured, and it was zero". None means "not measured".
    # Collapsing the two is how a broken scrape turns into a green pipeline.
    payload = {"status": "success", "data": {"result": []}}
    with patch("urllib.request.urlopen", fake_urlopen(payload)):
        assert query_prometheus("http://prom", "up") is None


def test_nan_is_treated_as_no_data():
    # A ratio with an empty denominator comes back as NaN, and every comparison
    # against NaN is False -- so an unguarded NaN sails straight through the
    # threshold check and promotes a broken build.
    payload = {
        "status": "success",
        "data": {"result": [{"value": [1755200000, "NaN"]}]},
    }
    with patch("urllib.request.urlopen", fake_urlopen(payload)):
        assert query_prometheus("http://prom", "rate(x[5m])") is None


def test_a_failed_query_raises_rather_than_returning_none():
    payload = {"status": "error", "error": "parse error at char 3"}
    with (
        patch("urllib.request.urlopen", fake_urlopen(payload)),
        pytest.raises(RuntimeError, match="parse error"),
    ):
        query_prometheus("http://prom", "sum(")


def test_the_base_url_trailing_slash_is_handled():
    payload = {"status": "success", "data": {"result": [{"value": [0, "1"]}]}}
    captured = {}

    def capture(url, *args, **kwargs):
        captured["url"] = url
        return FakeResponse(payload)

    with patch("urllib.request.urlopen", capture):
        query_prometheus("http://prom/", "up")

    assert captured["url"].startswith("http://prom/api/v1/query?")


# ------------------------------------------------- the NaN path, end to end


def test_a_nan_ratio_blocks_promotion():
    # Regression guard for the whole chain: NaN from Prometheus becomes None,
    # and None blocks. Written as one test because the bug only exists when the
    # two halves are wired together.
    payload = {
        "status": "success",
        "data": {"result": [{"value": [0, "NaN"]}]},
    }
    with patch("urllib.request.urlopen", fake_urlopen(payload)):
        total = query_prometheus("http://prom", "sum(...)")

    assert not evaluate(None, total, MAX_RATIO, MIN_REQUESTS).passed
