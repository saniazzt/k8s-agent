# Fault library

Applied and reverted with `./scripts/fault.sh apply|revert <id>` (the operator's
tool — the agent must never run these).

| id | fault | type | Expected symptom |
|---|---|---|---|
| 01 | missing-env | easy | CrashLoopBackOff; log `FATAL missing required env: ['DB_HOST']` |
| 02 | oom-limit | easy | CrashLoopBackOff; describe → `Last State: Terminated (OOMKilled, 137)` |
| 03 | bad-image-tag | easy | `ImagePullBackOff`; event `manifest unknown` |
| 04 | unschedulable-requests | easy | `Pending`; event `Insufficient memory/cpu` |
| 05 | missing-storageclass | easy | `Pending`; event `storageclass "fast-ssd-DOES-NOT-EXIST" not found` |
| 06 | service-selector-mismatch | hard | Pods Ready, endpoints `<none>`; callers time out |
| 07 | configmap-key-rename | hard | Pods stuck `ContainerCreating`; event `couldn't find key LOG_LEVEL` |
| 08 | networkpolicy-blocks-db | hard | Pods Ready, no events; app logs `db unreachable: timed out` |
| 09 | readiness-404 | hard | Running `0/1 Ready`; readiness probe 404; endpoints empty |
| 10 | dns-broken | hard | Pods Ready; app logs name-resolution failures for `demo-db` |

Notes:

- 01, 04, 05 and 07 change what the *scheduler/kubelet* sees (events tell the story).
- 06, 08, 09 and 10 look healthy at the pod level — they require correlating
  Service selectors, NetworkPolicies, probe config and `dnsConfig` with the logs.
- `05` uses two files (`05-pvc.yaml` + `05-mount.yaml`) because it needs both a
  new object and a deployment patch.
