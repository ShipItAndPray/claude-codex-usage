#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Policy:
    name: str
    success_low: int
    success_mid: int
    success_high: int
    retry_first: int
    retry_second: int
    retry_third: int
    hide_transient_status: bool
    keep_last_good_values: bool
    codex_active: int


POLICIES = [
    Policy(
        name="baseline",
        success_low=180,
        success_mid=120,
        success_high=60,
        retry_first=120,
        retry_second=300,
        retry_third=600,
        hide_transient_status=False,
        keep_last_good_values=True,
        codex_active=20,
    ),
    Policy(
        name="candidate_a",
        success_low=600,
        success_mid=420,
        success_high=300,
        retry_first=900,
        retry_second=1800,
        retry_third=3600,
        hide_transient_status=True,
        keep_last_good_values=True,
        codex_active=20,
    ),
    Policy(
        name="candidate_b",
        success_low=900,
        success_mid=600,
        success_high=300,
        retry_first=1200,
        retry_second=2400,
        retry_third=3600,
        hide_transient_status=True,
        keep_last_good_values=True,
        codex_active=45,
    ),
]


def evals(policy: Policy) -> list[bool]:
    return [
        policy.keep_last_good_values,
        policy.hide_transient_status,
        policy.retry_first >= 900,
        policy.success_low >= 300 and policy.success_mid >= 300 and policy.success_high >= 300,
        policy.codex_active <= 30,
    ]


print("experiment\tscore\tmax_score\tpass_rate\tstatus\tdescription")
max_score = 5
for index, policy in enumerate(POLICIES):
    score = sum(evals(policy))
    status = "baseline" if index == 0 else ("keep" if score == max_score else "discard")
    description = {
        "baseline": "current refresh policy from app",
        "candidate_a": "quiet stale Claude values, 5-10 minute success cadence, 15-60 minute 429 backoff",
        "candidate_b": "extra-conservative Claude cadence with slower Codex refresh",
    }[policy.name]
    pass_rate = f"{(score / max_score) * 100:.1f}%"
    print(f"{index}\t{score}\t{max_score}\t{pass_rate}\t{status}\t{description}")
