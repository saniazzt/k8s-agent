#!/usr/bin/env python3
"""Minimal MCP (stdio) server exposing read-only VictoriaMetrics queries.

Tools:
  vm_query          - instant PromQL/MetricsQL query
  vm_query_range    - range query over [start, end] with step
  vm_label_values   - list values of a label (discover metrics/jobs)

No write API is exposed (no /api/v1/write, no delete). Uses only stdlib.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

VM_URL = os.environ.get("VM_URL", "http://127.0.0.1:8429").rstrip("/")
VM_TENANT_PATH = os.environ.get("VM_TENANT_PATH", "")  # e.g. "/prometheus" for prom-compat
# Set when the endpoint sits behind a host-routed ingress (Traefik): the
# request must carry the ingress host, not the node IP.
VM_HOST_HEADER = os.environ.get("VM_HOST_HEADER", "")
PROTOCOL = "2024-11-05"
TIMEOUT = 20

TOOLS = [
    {
        "name": "vm_query",
        "description": "Run an instant PromQL/MetricsQL query against VictoriaMetrics and return the raw series.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "PromQL/MetricsQL expression, e.g. up{job=\"backend\"}"},
                "time": {"type": "string", "description": "Optional RFC3339 or unix timestamp"},
            },
            "required": ["query"],
        },
    },
    {
        "name": "vm_query_range",
        "description": "Run a range query (values over time) against VictoriaMetrics. Useful to correlate a symptom with a metric change.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "start": {"type": "string", "description": "RFC3339 or unix; e.g. -1h is not supported - pass explicit time"},
                "end": {"type": "string", "description": "RFC3339 or unix"},
                "step": {"type": "string", "description": "Resolution, e.g. 30s"},
            },
            "required": ["query", "start", "end"],
        },
    },
    {
        "name": "vm_label_values",
        "description": "List the values of a label (e.g. metric names via __name__, or jobs via job) to discover what exists.",
        "inputSchema": {
            "type": "object",
            "properties": {"label": {"type": "string", "description": 'e.g. "__name__" or "job"'}},
            "required": ["label"],
        },
    },
]


def api(path: str, params: dict) -> dict:
    url = f"{VM_URL}{VM_TENANT_PATH}{path}?{urllib.parse.urlencode(params)}"
    headers = {"Accept": "application/json"}
    if VM_HOST_HEADER:
        headers["Host"] = VM_HOST_HEADER
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def call_tool(name: str, args: dict) -> str:
    if name == "vm_query":
        out = api("/api/v1/query", {"query": args["query"], **({"time": args["time"]} if args.get("time") else {})})
    elif name == "vm_query_range":
        out = api(
            "/api/v1/query_range",
            {
                "query": args["query"],
                "start": args["start"],
                "end": args["end"],
                "step": args.get("step", "30s"),
            },
        )
    elif name == "vm_label_values":
        out = api(f"/api/v1/label/{urllib.parse.quote(args['label'])}/values", {})
    else:
        raise ValueError(f"unknown tool: {name}")

    result = out.get("data", {}).get("result", [])
    if not result:
        return "no data for this query"
    # keep the payload readable: cap series and points
    return json.dumps(result[:20], ensure_ascii=False)[:12000]


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
                "serverInfo": {"name": "victoriametrics-readonly", "version": "1.0.0"},
            },
        })
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        params = request.get("params") or {}
        name = params.get("name", "")
        args = params.get("arguments") or {}
        try:
            text = call_tool(name, args)
            send({"jsonrpc": "2.0", "id": req_id, "result": {"content": [{"type": "text", "text": text}], "isError": False}})
        except (urllib.error.URLError, ValueError, KeyError) as exc:
            send({"jsonrpc": "2.0", "id": req_id, "result": {"content": [{"type": "text", "text": f"error: {exc}"}], "isError": True}})
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": req_id, "result": {}})
    elif method and method.startswith("notifications/"):
        return  # no response for notifications
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
