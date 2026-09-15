#!/usr/bin/env bash
# test-hooks.sh — prove the two hooks work, without needing a model.
#
# Feeds realistic Claude Code hook payloads into the hook scripts and prints the
# verdict for each. The last two cases are the ones the workshop grades:
#   1. a mutating command must be denied
#   2. a secret read must be denied
#   3. a read-only command must pass
#   4. an MCP mutation tool must be denied
#   5. output containing the secret must be redacted (PostToolUse)
#
#   ./scripts/test-hooks.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BLOCK="$ROOT/scripts/block_mutations.py"
REDACT="$ROOT/scripts/redact_secrets.py"
SECRET_LIST="$ROOT/.rca/secret-values.txt"

pass=0; fail=0
verdict() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  PASS  $1 -> $3"; pass=$((pass+1));
  else echo "  FAIL  $1 -> got '$3', expected '$2'"; fail=$((fail+1)); fi
}

pre() { # tool_name command  => deny | allow
  local out
  out="$(printf '%s' "$1" | python3 "$BLOCK")"
  if printf '%s' "$out" | grep -q '"permissionDecision": "deny"'; then echo deny; else echo allow; fi
}

mcp() { # tool_name => deny | allow
  local out
  out="$(printf '%s' "$1" | python3 "$BLOCK")"
  if printf '%s' "$out" | grep -q '"permissionDecision": "deny"'; then echo deny; else echo allow; fi
}

echo "PreToolUse — mutations must be denied"
verdict "kubectl delete pod"      deny  "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl delete pod demo-app-abc -n rca-test"}}')"
verdict "kubectl apply -f"        deny  "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl apply -f fix.yaml -n rca-test"}}')"
verdict "kubectl scale"           deny  "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl -n rca-test scale deploy/demo-app --replicas=3"}}')"
verdict "kubectl exec"            deny  "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl exec -it demo-app-abc -n rca-test -- sh"}}')"
verdict "helm upgrade"            deny  "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"helm upgrade demo ./chart"}}')"

echo
echo "PreToolUse — secret reads must be denied"
verdict "kubectl get secret -o yaml" deny "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl get secret demo-secrets -n rca-test -o yaml"}}')"
verdict "kubectl describe secret"    deny "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl describe secret demo-secrets -n rca-test"}}')"
verdict "printenv DB_PASSWORD"       deny "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printenv DB_PASSWORD"}}')"
verdict "read serviceaccount token"  deny "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/var/run/secrets/kubernetes.io/serviceaccount/token"}}')"

echo
echo "PreToolUse — read-only investigation must pass"
verdict "kubectl get pods"    allow "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl get pods -n rca-test -o wide"}}')"
verdict "kubectl logs"        allow "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl logs -n rca-test deploy/demo-app --previous --tail=50"}}')"
verdict "kubectl get events"  allow "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl get events -n rca-test --sort-by=.lastTimestamp"}}')"
verdict "kubectl get cm yaml" allow "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl get configmap demo-app-config -n rca-test -o yaml"}}')"
verdict "auth can-i"          allow "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"kubectl auth can-i get pods --as=system:serviceaccount:rca-test:rca-agent -n rca-test"}}')"

echo
echo "PreToolUse — local files containing a known secret must not be printed"
SECVAL="$(head -1 "$SECRET_LIST" 2>/dev/null || true)"
if [ -n "$SECVAL" ]; then
  printf '%s' "$SECVAL" > /tmp/rca-secret-probe.txt
  verdict "cat a file with a secret"  deny "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat /tmp/rca-secret-probe.txt"}}')"
  verdict "Read tool on that file"    deny "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/rca-secret-probe.txt"}}')"
  verdict "cat a normal file"         allow "$(pre '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat README.md"}}')"
  rm -f /tmp/rca-secret-probe.txt
fi

echo
echo "PreToolUse — MCP tools"
verdict "mcp pods_delete"     deny  "$(mcp '{"hook_event_name":"PreToolUse","tool_name":"mcp__kubernetes__pods_delete","tool_input":{"name":"demo-app-abc"}}')"
verdict "mcp pods_get"        allow "$(mcp '{"hook_event_name":"PreToolUse","tool_name":"mcp__kubernetes__pods_get","tool_input":{"name":"demo-app-abc"}}')"
verdict "mcp secrets_get"     deny  "$(mcp '{"hook_event_name":"PreToolUse","tool_name":"mcp__kubernetes__secrets_get","tool_input":{"name":"demo-secrets"}}')"

echo
echo "PostToolUse — secret values in output must be redacted"
SECRET_VALUE="$(head -1 "$SECRET_LIST" 2>/dev/null || echo SUPER_SECRET_DB_PASSWORD_***)"
OUT="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"env"},"tool_response":"PATH=/usr/bin\\nDB_PASSWORD=%s\\nDB_HOST=demo-db"}' "$SECRET_VALUE" | python3 "$REDACT")"
if printf '%s' "$OUT" | grep -q '\*\*\*REDACTED\*\*\*'; then
  echo "  PASS  known secret value redacted"; pass=$((pass+1))
else
  echo "  FAIL  known secret value NOT redacted"; fail=$((fail+1))
fi
if printf '%s' "$OUT" | grep -q "$SECRET_VALUE"; then
  echo "  FAIL  secret value still present in output"; fail=$((fail+1))
else
  echo "  PASS  secret value absent from output"; pass=$((pass+1))
fi

OUT2="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{},"tool_response":"api_key: abcd1234secretvalue5678"}' | python3 "$REDACT")"
verdict "generic credential pattern" "redacted" "$(printf '%s' "$OUT2" | grep -q '\*\*\*REDACTED\*\*\*' && echo redacted || echo leaked)"

echo
echo "------------------------------------------"
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
