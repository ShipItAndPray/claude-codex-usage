## Experiment 0 - baseline

Score: 2/5 (40%)
Change: Recorded the current scheduler and menu behavior.
Reasoning: Establish the starting point before changing intervals.
Result: Claude already preserved last good values, and Codex remained fast. The policy still failed on user-facing transient status and Claude polling frequency.
Remaining failures: Claude success cadence is too aggressive, Claude `429` backoff is too short, and rate-limit language leaks into the UI.

## Experiment 1 - keep

Score: 5/5 (100%)
Change: Switched Claude to a quiet stale-value policy with a 5-10 minute healthy cadence and a 15-60 minute `429` backoff.
Reasoning: The endpoint should be treated as scarce network metadata, not as a near-real-time signal.
Result: All evals passed without slowing Codex.
Remaining failures: Claude still cannot show fresh numbers if Anthropic rate-limits before the app has ever seen one successful snapshot.

## Experiment 2 - discard

Score: 4/5 (80%)
Change: Tried an even more conservative Claude cadence and slower Codex cadence.
Reasoning: Test whether extra caution improves reliability without harming usefulness.
Result: Claude remained safe, but Codex stopped feeling live enough.
Remaining failures: Codex freshness regressed.
