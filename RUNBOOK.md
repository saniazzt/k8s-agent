# RUNBOOK — running the RCA plugin against the cluster

## 0. Mental model: where each piece runs

The plugin does **not** run inside a pod. Claude Code is a **read-only client**
on your operator machine that talks to the cluster API server over HTTPS:

```
 your machine (operator)                          k3s cluster
┌────────────────────────────────────┐          ┌──────────────────────────────┐
│  Claude Code  +  rca-agent plugin  │  HTTPS   │  API server :6443            │
│    ├─ kubernetes MCP ──────────────┼─────────▶│   RBAC: rca-agent SA         │
│    │    (restricted kubeconfig)    │          │   get/list/watch only        │
│    ├─ PreToolUse hook  ── deny     │          │   NO secrets                 │
│    └─ PostToolUse hook ── redact   │          │                              │
└────────────────────────────────────┘          │  ns rca-test:                │
                                                │   demo-app, demo-db, ...     │
                                                └──────────────────────────────┘
```

Three independent guards, so safety does not depend on the model behaving:

1. **RBAC (server side)** — the token literally cannot delete/patch/exec, and
   has **no** `secrets` permission. Even a bypassed hook gets `Forbidden`.
2. **PreToolUse hook (client)** — blocks mutation verbs and secret reads before
   they run, including the kubernetes MCP tools.
3. **PostToolUse hook (client)** — redacts known secret values from any output.

## 0b. QUICK START (copy-paste, works today)

`claude` is not on `PATH` (it ships inside the VS Code extension), and the
gateway/cluster are only reachable through the local proxy on
`127.0.0.1:1087`. So:

```bash
cd "/Users/saniaezzati/Desktop/Hamamooz-Session-tasks/week 4/rca-agent"

# one-time: put the CLI on PATH
ln -sf ~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude \
       /opt/homebrew/bin/claude
rehash                       # zsh caches command lookups

# every session: proxy + the read-only cluster credentials
export HTTPS_PROXY=http://127.0.0.1:1087
export HTTP_PROXY=http://127.0.0.1:1087
export NO_PROXY=localhost,127.0.0.1          # NOT the cluster IP!
export KUBECONFIG="$PWD/.rca/kubeconfig-rca-agent"

claude --plugin-dir .        # then:  /k8s-rca:rca rca-test
```

Headless one-shot:

```bash
claude -p "/k8s-rca:rca rca-test" --plugin-dir . --output-format json
```

Gotchas that cost real debugging time:

| symptom | cause | fix |
|---|---|---|
| `zsh: command not found: claude` | CLI lives in the VS Code extension dir | symlink into `/opt/homebrew/bin` (above) |
| `⚠ Claude Sonnet 4 was retired` | system clock is **2026**, model id `anthropic/claude-sonnet-4.5` looks old | cosmetic; or set `model` to a newer Claude in `~/.claude/settings.json` |
| request hangs / TLS `SSL_ERROR_SYSCALL` | direct traffic to the gateway is DPI-blocked | set `HTTPS_PROXY` (above) |
| `Unable to connect to the server: EOF` | cluster API only reachable *through* the proxy | set `HTTPS_PROXY`, and **remove the cluster IP from `NO_PROXY`** |
| `/rca` → "Unknown command" | plugin commands are namespaced | use `/k8s-rca:rca` |
| MCP tools missing / `mcp-config-invalid` | see §8 | install `mcp-server-kubernetes` globally; hooks key must not be in `plugin.json` |

## 1. Prerequisites

- `node` / `npx` (for the `kubernetes` MCP server)
- `python3` (hooks + the victoriametrics/alertmanager MCP servers)
- Claude Code CLI, already pointed at the gateway (`~/.claude/settings.json`
  with `ANTHROPIC_BASE_URL=https://ai.hamravesh.ir/gateway`)
- admin `kubectl` **only** for setup and for injecting practice faults

## 2. One-time cluster setup (as cluster admin)

On the master node (k3s):

```bash
ssh ubuntu@95.38.160.59
cd /tmp/rca-agent                 # or wherever the repo is on the server
export KUBECTL="sudo k3s kubectl"
export RCA_SERVER="https://95.38.160.59:6443"     # endpoint your laptop can reach
./scripts/setup.sh
```

`setup.sh` creates:

| artifact | purpose |
|---|---|
| `ns/rca-test` + demo app | the thing being debugged |
| SA `rca-agent` + read-only Role/ClusterRole | the agent's identity |
| `.rca/kubeconfig-rca-agent` | restricted kubeconfig (token + CA, `chmod 600`) |
| `.rca/secret-values.txt` | redaction source, **gitignored**, never read by the model |

It prints RBAC checks — expected `no / yes / no / no`:

```
  delete pods      : no
  get pods         : yes
  get secrets      : no
  scale deployments: no
```

Then copy the restricted kubeconfig to your laptop (already present here):

```bash
scp ubuntu@95.38.160.59:/tmp/rca-agent/.rca/kubeconfig-rca-agent \
    "/Users/saniaezzati/Desktop/Hamamooz-Session-tasks/week 4/rca-agent/.rca/"
```

Confirm your laptop can use it directly (public API endpoint, no tunnel needed):

```bash
cd "/Users/saniaezzati/Desktop/Hamamooz-Session-tasks/week 4/rca-agent"
KUBECONFIG=.rca/kubeconfig-rca-agent kubectl get pods -n rca-test
```

## 3. Verify the guardrails

```bash
./scripts/test-hooks.sh        # must be 23/23
```

## 4. Run the plugin

Interactive (recommended — you can watch the investigation):

```bash
cd "/Users/saniaezzati/Desktop/Hamamooz-Session-tasks/week 4/rca-agent"
export HTTPS_PROXY=http://127.0.0.1:1087 HTTP_PROXY=http://127.0.0.1:1087
export NO_PROXY=localhost,127.0.0.1
export KUBECONFIG="$PWD/.rca/kubeconfig-rca-agent"
claude --plugin-dir .
```

Inside the TUI:

- `/mcp` → confirm `kubernetes`, `victoriametrics`, `alertmanager` are **connected**
- `/k8s-rca:rca rca-test` → full read-only investigation + report
  (plugin commands are namespaced as `/<plugin>:<command>`; plain `/rca` is not found)
- `/rbac-check` → re-verify the RBAC guardrails from inside Claude
- `/k8s-rca:break-it` → apply a practice fault (operator side)

Headless / scriptable (what we used for the 10-fault benchmark):

```bash
claude -p "/k8s-rca:rca rca-test" \
  --plugin-dir . \
  --allowedTools "mcp__kubernetes" "mcp__victoriametrics" "mcp__alertmanager" \
    "Bash(kubectl get:*)" "Bash(kubectl describe:*)" "Bash(kubectl logs:*)" \
    "Bash(kubectl top:*)" "Bash(kubectl auth can-i:*)" Read Grep Task \
  --output-format json
```

## 5. Debugging with it — what to ask

You do not have to know the fault. Any of these works:

```
/k8s-rca:rca rca-test
the rca-test namespace is broken, investigate read-only
why are the demo-app pods not ready in rca-test?
demo-app cannot reach its database — find the root cause
```

It follows `skills/k8s-rca/SKILL.md` in order:
`pods → events → describe → logs --previous → deployment yaml → endpoints → metrics → hypothesis`.

MCP tools it may use:

| server | gives it |
|---|---|
| `kubernetes` | get/list/watch/logs/events/top via the restricted kubeconfig |
| `victoriametrics` | `hamamooz_*` app metrics, `up`, resource series |
| `alertmanager` | which alert fired and since when (needs a port-forward) |
| `grafana` | dashboards (needs a port-forward + `GRAFANA_API_KEY`) |

The last two are optional — RCA works with `kubernetes` + `victoriametrics` alone.
To enable them:

```bash
kubectl port-forward -n monitoring-system svc/vmalertmanager-vmalertmanager 9093:9093 &
kubectl port-forward -n monitoring-system svc/grafana 3000:3000 &
```

Every answer comes back in the fixed format:

```
ROOT CAUSE: <one sentence>
EVIDENCE:   - <command> -> <what it showed>
CONFIDENCE: high | medium | low
PROPOSED PATCH: <yaml>
```

The patch is **proposed only** — you apply it, if you agree. A wrong-but-confident
answer is explicitly worse than "insufficient evidence".

## 6. Practice: inject a fault, then debug it

Faults are applied by the **operator** (never by the agent):

```bash
# on the master
ssh ubuntu@95.38.160.59
cd /tmp/rca-agent
export KUBECTL="sudo k3s kubectl"
./scripts/fault.sh list
./scripts/fault.sh apply 09        # readiness probe -> /nope
```

Then from your laptop: `/rca rca-test`. When done:

```bash
./scripts/fault.sh revert 09       # or: revert all
```

10 faults are available (`faults/README.md`): missing env, OOM limit,
bad image tag, unschedulable requests, missing StorageClass, service selector
mismatch, ConfigMap key rename, NetworkPolicy egress block, readiness 404,
broken DNS.

## 7. Debugging a namespace other than rca-test

The agent is scoped on purpose. To widen it:

1. **RBAC** — add a `Role`/`RoleBinding` for `rca-agent` in the target namespace
   (same rules as `k8s/rbac.yaml`, still without `secrets`).
2. **Context** — update `CLAUDE.md` (target namespace + "where the evidence
   lives") and, if the topology differs, `skills/k8s-rca/SKILL.md`.
3. Run `/rca <that-namespace>`.

Keep `secrets` out of the Role. That single omission is what makes the
"never reveal a secret" rule structural rather than prompt-based.

## 8. Troubleshooting

| symptom | cause / fix |
|---|---|
| `/mcp` shows `kubernetes` failed | `npx mcp-server-kubernetes` cache can be corrupt (`Cannot find module 'ajv'`). Install it globally (`npm i -g mcp-server-kubernetes`) — the plugin config now calls the binary directly, not `npx` |
| plugin MCP servers silently disabled | `plugin.json` must **not** contain `"hooks": "./hooks/hooks.json"`: `hooks/hooks.json` is auto-loaded, and declaring it again makes Claude Code fail the plugin with *Duplicate hooks file detected* (this also disables the plugin's MCP servers). MCP is declared in `.claude-plugin/mcp.json` |
| `GRAFANA_API_KEY` / `mcp-grafana` errors | Grafana MCP is optional and not shipped by default; add your own `--mcp-config` if you want it |
| `NO_PROXY` contains the cluster IP | makes the MCP/kubectl go direct → `EOF`. Only bypass `localhost,127.0.0.1` |
| `Forbidden` on a normal read | RBAC is working as designed for that verb; reads are `get/list/watch` only |
| `alertmanager`/`grafana` MCP failed | the port-forwards from §5 are not running |
| gateway auth error | re-check `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` in `~/.claude/settings.json` |
| a hook blocks a legitimate command | the deny list is verb-based; rephrase as a read (`logs`, `describe`, `get -o yaml`) |
| the baseline looks broken before a run | on the operator: `./scripts/fault.sh revert all` (rebuilds the workload from the base manifest) |

## 9. Optional: running it inside the cluster (headless)

If you want scheduled/unattended RCA, run Claude Code as a short-lived Job with
the plugin baked into the image. Nothing here needs cluster write access, so the
pod runs with the same read-only SA:

```yaml
apiVersion: batch/v1
kind: Job
metadata: { name: rca-run, namespace: rca-test }
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      serviceAccountName: rca-agent          # the read-only SA
      restartPolicy: Never
      containers:
        - name: claude
          image: <your-image-with-claude-code-and-this-plugin>
          command: ["claude", "-p", "/rca rca-test", "--plugin-dir", "/plugin",
                    "--output-format", "json"]
          env:
            - { name: KUBECONFIG, value: /plugin/.rca/kubeconfig-rca-agent }
            - { name: ANTHROPIC_BASE_URL, value: https://ai.hamravesh.ir/gateway }
            - name: ANTHROPIC_AUTH_TOKEN
              valueFrom: { secretKeyRef: { name: claude-gateway, key: token } }
          # the in-cluster path can use the SA token directly instead of the
          # kubeconfig; mount it and set KUBERNETES_SERVICE_HOST accordingly.
```

Caveats: the token is a Secret here (the agent itself still cannot *read*
Secrets via RBAC); store the gateway key in a k8s Secret, not in the manifest;
and note the model call leaves the cluster to reach the gateway.
For interactive debugging, §4 on your laptop is the better workflow.
