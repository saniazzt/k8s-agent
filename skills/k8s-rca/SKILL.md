---
name: k8s-rca
description: Root-cause analysis for a broken Kubernetes namespace. Walks a fixed evidence order (pods → events → describe → logs --previous → deployment yaml → endpoints → hypothesis) using read-only commands only, then emits the mandatory RCA answer format. Use whenever the user reports a broken/unhealthy namespace, crashing pods, a failing deploy, or asks "why is X not working" in Kubernetes.
---

# k8s-rca — evidence order

> The order is mandatory. Skipping steps is the main cause of wrong answers:
> agents that jump straight to `logs` see an application error and stop, while
> the real cause is a missing env var, a mismatched selector, or a full node.

## Step 0 — Scope

```bash
kubectl get ns <ns>
kubectl get all -n <ns> -o wide
kubectl auth can-i --list --as=system:serviceaccount:<ns>:rca-agent -n <ns>   # optional sanity check
```

Note which objects are `NotReady`, `CrashLoopBackOff`, `Pending`, or missing.
Write down the candidate names before continuing.

## Step 0b — Is it broken *right now*?

Before explaining anything, establish that the fault is **current**:

```bash
kubectl get pods -n <ns> -o wide          # all Ready? any restarts happening now?
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -25
date -u +%Y-%m-%dT%H:%M:%SZ               # compare against event timestamps
```

- Events are kept for ~1h and the cluster has been churned by earlier experiments.
  **Only events in the last few minutes, matching a currently-unhealthy pod, are evidence.**
- If every pod is `Ready` with `0` recent restarts and there are no *current*
  failures, the honest answer is **"no active fault — the errors in the event log
  are historical"**. Do **not** invent a cause from stale events. (This exact
  mistake produced a `high`-confidence wrong answer on a healthy namespace.)

## Step 1 — Pods (state first, no interpretation)

```bash
kubectl get pods -n <ns> -o wide
kubectl get pods -n <ns> -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,REASON:.status.containerStatuses[*].state.waiting.reason,RESTARTS:.status.containerStatuses[*].restartCount,NODE:.spec.nodeName'
```

Read the **state/reason** literally: `Pending`, `CrashLoopBackOff`,
`ImagePullBackOff`, `OOMKilled`, `CreateContainerConfigError`,
`Running but not Ready`. The reason narrows the next steps.

## Step 2 — Events (namespace-wide correlation)

```bash
kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -40
```

Events explain things pods cannot: `FailedScheduling`, `FailedMount`,
`FailedCreate`, image pull failures, readiness probe failures, and
"missing" references (ConfigMap/Secret/ServiceAccount not found).

## Step 3 — Describe the failing object

```bash
kubectl describe pod -n <ns> <pod>
kubectl describe deploy -n <ns> <deploy>      # conditions, unavailable replicas, events
```

Look for: `Last State: Terminated (Reason: OOMKilled, Exit Code: 137)`,
`Liveness/Readiness probe failed`, `Warning  Failed  kubelet  Error: ...`,
`MountVolume.SetUp failed`, `Nodes are available: ... Insufficient memory`.

## Step 4 — Logs of the previous container

```bash
kubectl logs -n <ns> <pod> --previous --tail=80     # the run that died
kubectl logs -n <ns> <pod> --tail=80                # current run
kubectl logs -n <ns> deploy/<deploy> --tail=80      # all pods of a deployment
```

`--previous` is mandatory when a container restarted — the current container's
empty log is itself a clue (crash before it could log).

## Step 5 — The workload's own YAML

```bash
kubectl get deploy -n <ns> <deploy> -o yaml
kubectl get configmap,secret -n <ns>          # names/keys only, never values
```

Compare against what the app says it needs:
- env vars vs. what the logs complain about (e.g. `DB_HOST` unset),
- `resources.requests/limits` vs. what `describe` reported,
- `image` tag vs. what the registry actually has,
- `readinessProbe.path`/`port` vs. what the app serves,
- `volumeMounts` / `volumes` and their `subPath` / keys.

## Step 6 — Endpoints & networking (only if traffic is the symptom)

```bash
kubectl get endpoints -n <ns> <svc> -o wide
kubectl get svc -n <ns> <svc> -o yaml
kubectl get networkpolicy -n <ns> -o yaml
```

An endpoint list that is `<none>` means the **Service selector does not match
any pod labels** — compare `spec.selector` with the pods' labels directly,
character by character. Do the same for the dependency's Service
(e.g. `demo-db`) when the app reports connection errors.

## Step 6b — When pods are Ready but the app still fails

This is the hardest class and the one that produced a confident wrong answer in
testing. Pods `1/1 Running`, probes passing, no events — and the app still
cannot reach its dependency. Before any hypothesis:

```bash
kubectl get deploy -n <ns> <deploy> -o yaml | grep -A6 -E "dnsPolicy|dnsConfig|securityContext|affinity"
kubectl get networkpolicy -n <ns> -o yaml
kubectl get endpoints -n <ns> <dependency-svc> -o wide
kubectl get svc -n <ns> <app-svc> -o yaml   # compare selector with pod labels
kubectl logs -n <ns> deploy/<deploy> --tail=50   # look for name-resolution errors
```

Rules learned the hard way:
- Read the **whole** deployment YAML — do not query only selected fields with
  `jsonpath`; you will miss `dnsConfig`, `dnsPolicy`, probes, `items:` and
  `securityContext`.
- If the logs show `timed out` / `[Errno -3] Try again` / `Name or service not
  known`, treat **DNS and NetworkPolicy** as primary suspects, not the app.
- A benign-looking oddity (e.g. an `items:` restriction on a volume that is not
  what the app reads) is **not** the root cause. If it does not explain the
  observed symptom, discard it — do not build a story around it.
- Correlate: does the failing dependency resolve? (`nslookup`/`getent` from a
  debug pod is forbidden to create; instead compare `dnsConfig`/`dnsPolicy` and
  the Service/endpoints).

## Step 7 — Only now: hypothesise

Form at most two candidate causes. For each, name the evidence that would
confirm or falsify it, and prefer the reading that explains **all** observed
symptoms, not just one.

Correlate: symptom time vs. event time vs. metric change (via the
`victoriametrics` MCP: `query`/`query_range`) vs. alert start (via
`alertmanager` MCP). A restart that coincides with an alert or a config change
is far more likely to be causal than a coincidental error string.

## Step 8 — Answer in the mandatory format

```
ROOT CAUSE: <one sentence>

EVIDENCE:
  - <command> -> <what it showed>

CONFIDENCE: high | medium | low

PROPOSED PATCH:
  <yaml>
```

Rules for the answer:
- One sentence for the cause; no hedging and no essay.
- Every EVIDENCE line is a command you actually ran and its real result.
- `PROPOSED PATCH` is **proposed only** — never applied. If the fix needs more
  than one object, emit one patch per object.
- If the evidence does not identify the cause: `CONFIDENCE: low` and say which
  command or piece of access is missing. That is a *better* answer than a guess.

## Anti-patterns (observed failures)

| Anti-pattern | Why it fails |
|---|---|
| Reading logs first and declaring the app broken | the app may be fine; the env/config/selector may be wrong |
| Trusting `Running` as healthy | `Running` + `0/1 Ready` is a ready-probe/config problem |
| Ignoring `--previous` | the crash reason is usually in the dead container's log |
| Blaming DNS/kernel/"the cluster" without evidence | unfalsifiable; use it only with a concrete failing lookup |
| Applying a fix to test it | forbidden; propose the patch instead |
| Confident answer with one weak signal | graded worse than "insufficient evidence" |
