#!/usr/bin/env python3
"""Minimal MCP (stdio) server exposing read-only Alertmanager queries.

Tools:
  am_alerts   - active/firing alerts (what fired, since when, labels/annotations)
  am_silences - current silences (to know whether an alert was intentionally muted)
  am_status   - Alertmanager cluster status/version

Read-only: no silence creation/deletion, no alert resolution. Uses only stdlib.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

AM_URL = os.environ.get("AM_URL", "http://127.0.0.1:9093").rstrip("/")
AM_PATH = os.environ.get("AM_PATH", "")
AM_HOST_HEADER = os.environ.get("AM_HOST_HEADER", "")
PROTOCOL = "2024-11-05"
TIMEOUT = 20

TOOLS = [
    {
        "name": "am_alerts",
        "description": "List alerts from Alertmanager with their state, labels, annotations and start time. Use to correlate a symptom with when an alert began firing.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "only_firing": {"type": "boolean", "description": "default true: return only active (firing) alerts"},
                "filter": {"type": "string", "description": "optional label filter, e.g. alertname=ClusterApiBackendDown"},
            },
        },
    },
    {
        "name": "am_silences",
        "description": "List current silences — tells whether an alert was deliberately muted (an alert's absence may be meaningless).",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "am_status",
        "description": "Alertmanager status/version and uptime — confirms the alerting pipeline itself is healthy.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def api(path: str, params: dict | None = None) -> object:
    url = f"{AM_URL}{AM_PATH}{path}"
    if params:
        url += f"?{urllib.parse.urlencode(params)}"
    headers = {"Accept": "application/json"}
    if AM_HOST_HEADER:
        headers["Host"] = AM_HOST_HEADER
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def call_tool(name: str, args: dict) -> str:
    if name == "am_alerts":
        params = {}
        if args.get("only_firing", True):
            params["active"] = "true"
        if args.get("filter"):
            params["filter"] = args["filter"]
        alerts = api("/api/v2/alerts", params or None)
        slim = [
            {
                "alertname": a.get("labels", {}).get("alertname"),
                "state": (a.get("status") or {}).get("state"),
                "startsAt": a.get("startsAt"),
                "labels": a.get("labels"),
                "annotations": a.get("annotations"),
            }
            for a in alerts
        ]
        return json.dumps(slim[:40], ensure_ascii=False)[:12000] if slim else "no matching alerts"
    if name == "am_silences":
        silences = api("/api/v2/silences")
        return json.dumps(silences[:40], ensure_ascii=False)[:8000] if silences else "no silences"
    if name == "am_status":
        return json.dumps(api("/api/v2/status"), ensure_ascii=False)[:4000]
    raise ValueError(f"unknown tool: {name}")


def send(message: dict) -> None:
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def handle(request: dict) -> None:
    method = request.get("method")
    req_id = request.get("id")
    if method == "initialize":
        send({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": PROTOCOL,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "alertmanager-readonly", "version": "1.0.0"},
            },
        })
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        params = request.get("params") or {}
        try:
            text = call_tool(params.get("name", ""), params.get("arguments") or {})
            send({"jsonrpc": "2.0", "id": req_id, "result": {"content": [{"type": "text", "text": text}], "isError": False}})
        except (urllib.error.URLError, ValueError) as exc:
            send({"jsonrpc": "2.0", "id": req_id, "result": {"content": [{"type": "text", "text": f"error: {exc}"}], "isError": True}})
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": req_id, "result": {}})
    elif method and method.startswith("notifications/"):
        return
    elif req_id is not None:
        send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": f"method not found: {method}"}})


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(request)


if __name__ == "__main__":
    main()
