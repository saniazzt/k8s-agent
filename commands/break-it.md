---
description: Inject an RCA exercise fault and record how the agent handled it (operator only — mutates rca-test).
argument-hint: <fault-id|list>
allowed-tools: Bash(./scripts/fault.sh:*), Bash(kubectl get:*), Bash(kubectl logs:*)
---

Fault id: **$1**

1. `./scripts/fault.sh list` if `$1` is `list`.
2. `./scripts/fault.sh apply $1`
3. Wait ~30 s, then record the agent-visible symptoms only (read-only commands):
   `kubectl get pods -n rca-test`, `kubectl get events -n rca-test --sort-by=.lastTimestamp | tail -20`
4. Ask the agent to investigate (see `/rca rca-test`), then fill in the results
   table in README.md: fault id, whether it found the cause, confidence,
   and whether it guessed where it should have investigated.

Remember: only the operator runs steps 1–2. Never ask the agent to apply or
revert a fault.
