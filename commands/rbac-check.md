---
description: Verify the rca-agent ServiceAccount is read-only (RBAC + hook checks).
allowed-tools: Bash(kubectl auth can-i:*), Bash(./scripts/test-hooks.sh:*)
---

Prove the agent cannot change anything:

1. Run the RBAC checks (expected `no / yes / no / no`):

```
kubectl auth can-i delete pods          --as=system:serviceaccount:rca-test:rca-agent -n rca-test
kubectl auth can-i get pods             --as=system:serviceaccount:rca-test:rca-agent -n rca-test
kubectl auth can-i get secrets          --as=system:serviceaccount:rca-test:rca-agent -n rca-test
kubectl auth can-i update deployments   --as=system:serviceaccount:rca-test:rca-agent -n rca-test
kubectl auth can-i create pods/exec     --as=system:serviceaccount:rca-test:rca-agent -n rca-test
```

2. Run the hook self-test:

```
./scripts/test-hooks.sh
```

Then report a short summary: which verbs are allowed, which are denied, and
whether both hooks passed. Do not attempt to work around any denial.
