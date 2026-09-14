#!/usr/bin/env python3
"""PreToolUse hook — block anything that would mutate the cluster or read secrets.

Reads the Claude Code hook payload from stdin and either stays silent (allow)
or emits a PreToolUse "deny" decision. Read-only investigation is never blocked.
"""

import json
import re
import sys

# --- mutation patterns -------------------------------------------------------

MUTATING_VERBS = (
    "apply", "create", "delete", "edit", "patch", "replace", "scale", "rollout",
    "annotate", "label", "set", "expose", "cordon", "uncordon", "drain", "taint",
    "exec", "cp", "proxy", "attach", "run", "expose",
)

MUTATION_PATTERNS = [
    # kubectl <verb> (flags may appear before the verb)
    re.compile(r"\bkubectl\b[^|;&]*?\b(%s)\b" % "|".join(MUTATING_VERBS)),
    re.compile(r"\bkubectl\s+auth\s+reconcile\b"),
    # helm / argocd / flux
    re.compile(r"\bhelm\s+(install|upgrade|uninstall|rollback|repo\s+(add|remove))\b"),
    re.compile(r"\bargocd\s+(sync|app\s+(set|delete|create)|rollback)\b"),
    re.compile(r"\bflux\s+(reconcile|suspend|resume|create|delete)\b"),
    # raw API writes
    re.compile(r"curl[^|;&]*(-X\s*(POST|PUT|PATCH|DELETE)|--request\s+(POST|PUT|PATCH|DELETE))[^|;&]*kube"),
    # write-capable kubectl from stdin/YAML
    re.compile(r"\bkubectl\b[^|;&]*\bscale\b"),
]

# --- secret-reading patterns -------------------------------------------------

SECRET_PATTERNS = [
    re.compile(r"\bkubectl\b[^|;&]*\bget\b[^|;&]*\bsecrets?\b"),          # covers -o yaml/json/jsonpath
    re.compile(r"\bkubectl\b[^|;&]*\bdescribe\b[^|;&]*\bsecrets?\b"),
    re.compile(r"\bkubectl\b[^|;&]*\bget\b[^|;&]*\b-o\s*(yaml|json)\b[^|;&]*\bsecrets?\b"),
    re.compile(r"\bkubectl\b[^|;&]*\bsecrets?\b[^|;&]*\b-o\s*(yaml|json|jsonpath)"),
    re.compile(r"\b(printenv|env)\b[^|;&]*(\||\s)\s*(grep|sort|head|tail)?[^|;&]*(PASS|SECRET|TOKEN|KEY)", re.I),
    re.compile(r"\bprintenv\s+\w*(PASS|SECRET|TOKEN|KEY)\w*", re.I),
    re.compile(r"\bcat\b[^|;&]*/(run|var/run)/secrets"),
    re.compile(r"\bbase64\b[^|;&]*(-d|--decode)"),
    re.compile(r"\bkubectl\b[^|;&]*\bsecret\b", re.I),
]

SECRET_READ_DENY_REASON = (
    "Blocked by rca-agent: reading Secret data is forbidden. "
    "Use key names / presence only (e.g. `kubectl get secret <name> -n <ns>` "
    "shows keys without values is still discouraged) — the RCA conclusion must "
    "not depend on a secret value."
)


def deny(reason: str) -> None:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    sys.exit(0)


def check_command(command: str) -> None:
    for rx in MUTATION_PATTERNS:
        if rx.search(command):
            deny(
                "Blocked by rca-agent: this command mutates cluster state "
                f"(matched {rx.pattern!r}). The agent is read-only — propose a "
                "YAML patch instead of applying it. Allowed: get, list, "
                "describe, logs, events, top, explain, auth can-i."
            )
    for rx in SECRET_PATTERNS:
        if rx.search(command):
            deny(SECRET_READ_DENY_REASON)


MCP_MUTATION_HINTS = re.compile(
    r"(apply|create|delete|patch|update|replace|scale|rollout|exec|drain|cordon|annotate|label|edit)",
    re.I,
)
MCP_SECRET_HINTS = re.compile(r"secret", re.I)


def check_mcp_tool(tool_name: str) -> None:
    low = tool_name.lower()
    if MCP_SECRET_HINTS.search(low) and re.search(r"(get|read|list|describe|show)", low):
        deny(SECRET_READ_DENY_REASON)
    if MCP_MUTATION_HINTS.search(low.split("__")[-1]):
        deny(
            "Blocked by rca-agent: this MCP tool can change cluster state. "
            "Use read-only tools (get/list/logs/events/top) and propose a "
            "YAML patch instead."
        )


def check_file_path(tool_input: dict) -> None:
    path = str(tool_input.get("file_path") or tool_input.get("path") or "")
    if re.search(r"(/run/secrets|/var/run/secrets|\.kube/config|kubeconfig)", path):
        deny(
            "Blocked by rca-agent: this path contains credentials "
            f"({path!r}). Reading it is forbidden."
        )


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # never break the session on malformed input

    tool_name = payload.get("tool_name", "") or ""
    tool_input = payload.get("tool_input") or {}

    if tool_name in ("Bash", "bash", "shell"):
        command = str(tool_input.get("command", ""))
        if command:
            check_command(command)
        sys.exit(0)

    if tool_name.startswith("mcp__"):
        check_mcp_tool(tool_name)
        sys.exit(0)

    if tool_name in ("Read", "read"):
        check_file_path(tool_input)

    sys.exit(0)


if __name__ == "__main__":
    main()
