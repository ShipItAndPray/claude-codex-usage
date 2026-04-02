# Claude Codex Usage Refresh Policy v2

## Goal

Make Claude usage feel seamless by treating it as a scarce network source and Codex as a cheap local source.

## Selected policy

- Preserve the last successful Claude values across transient failures.
- Do not surface transient Claude refresh errors in the menu bar, tooltip, or dropdown when a prior value already exists.
- Claude success cadence:
  - `5 minutes` when utilization is high or a reset is close
  - `7 minutes` when utilization is mid-range
  - `10 minutes` when utilization is low
- Claude `429` cadence:
  - first retry after `15 minutes`
  - second retry after `30 minutes`
  - subsequent retries after `60 minutes`
- Other Claude failures:
  - back off in `10 minute` steps when a last good value exists
- Codex active cadence:
  - `20 seconds`

## Why this won

- It passes all seamlessness evals.
- It still keeps Codex near-live.
- It removes the user-facing noise without hiding the core numbers.
