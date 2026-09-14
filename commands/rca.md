---
description: Investigate a broken Kubernetes namespace (read-only) and report root cause + proposed patch.
argument-hint: <namespace> [symptom]
allowed-tools: Bash(kubectl get:*), Bash(kubectl describe:*), Bash(kubectl logs:*), Bash(kubectl top:*), Bash(kubectl auth can-i:*), Read, Grep, Task
---

Investigate the namespace **$1** (symptom: ${2:-unknown}).

Follow `skills/k8s-rca/SKILL.md` strictly, in order:

1. `kubectl get ns $1` and `kubectl get all -n $1 -o wide`
2. `kubectl get pods -n $1 -o wide` (write down states/reasons)
3. `kubectl get events -n $1 --sort-by=.lastTimestamp | tail -40`
4. `kubectl describe pod -n $1 <failing-pod>` (and `describe deploy`)
5. `kubectl logs -n $1 <pod> --previous --tail=80`
6. `kubectl get deploy -n $1 <deploy> -o yaml` + `kubectl get configmap -n $1`
7. `kubectl get endpoints -n $1 <svc> -o wide` and compare selectors with pod labels
8. Correlate with metrics/alerts via the `victoriametrics` and `alertmanager` MCP tools
9. Only then form the hypothesis

Constraints (non-negotiable):
- read-only verbs only; never apply/delete/patch/scale/exec
- never read or print a Secret value
- if the evidence is insufficient, say so instead of guessing

If any command produced more than ~200 lines, hand it to the `log-summarizer`
subagent instead of reading it raw.

Reply **only** in this format:

```
ROOT CAUSE: <one sentence>

EVIDENCE:
  - <command> -> <what it showed>

CONFIDENCE: high | medium | low

PROPOSED PATCH:
  <yaml>
```
