#!/usr/bin/env bash
# setup.sh — install the exercise namespace, RBAC, restricted kubeconfig and
# the local secret-value list used by the redaction hook.
#
# Run as a cluster admin (the human operator):
#   export KUBECTL="sudo k3s kubectl"
#   ./scripts/setup.sh
set -euo pipefail

K="${KUBECTL:-kubectl}"
NS="rca-test"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RCA_DIR="$ROOT/.rca"
KUBECONFIG_OUT="$RCA_DIR/kubeconfig-rca-agent"
SECRET_LIST="$RCA_DIR/secret-values.txt"
SERVER="${RCA_SERVER:-https://127.0.0.1:6443}"

mkdir -p "$RCA_DIR"

echo "==> applying namespace + demo app"
$K apply -f "$ROOT/k8s/namespace.yaml"
echo "==> applying RBAC"
$K apply -f "$ROOT/k8s/rbac.yaml"

echo "==> waiting for the service-account token"
for _ in $(seq 1 30); do
  TOKEN="$($K get secret rca-agent-token -n "$NS" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -n "$TOKEN" ] && break
  sleep 2
done
CA="$($K get secret rca-agent-token -n "$NS" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
[ -n "$CA" ] || CA="$($K get configmap kube-root-ca.crt -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -w0)"

cat > "$KUBECONFIG_OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: rca
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: rca-agent
    user:
      token: ${TOKEN}
contexts:
  - name: rca
    context: { cluster: rca, user: rca-agent, namespace: ${NS} }
current-context: rca
EOF
chmod 600 "$KUBECONFIG_OUT"
echo "    wrote $KUBECONFIG_OUT"

# Local, gitignored list of secret VALUES used by the PostToolUse redaction hook.
# This file is never read by the model and never committed.
$K get secret demo-secrets -n "$NS" -o jsonpath='{.data.DB_PASSWORD}' | base64 -d > "$SECRET_LIST"
echo "    wrote $SECRET_LIST (redaction source, gitignored)"

echo
echo "==> RBAC verification (expected: no / yes / no)"
echo -n "  delete pods      : "; $K auth can-i delete pods --as="system:serviceaccount:${NS}:rca-agent" -n "$NS" || true
echo -n "  get pods         : "; $K auth can-i get pods --as="system:serviceaccount:${NS}:rca-agent" -n "$NS" || true
echo -n "  get secrets      : "; $K auth can-i get secrets --as="system:serviceaccount:${NS}:rca-agent" -n "$NS" || true
echo -n "  scale deployments: "; $K auth can-i update deployments --as="system:serviceaccount:${NS}:rca-agent" -n "$NS" || true

echo
echo "==> done. Point the kubernetes MCP server at:"
echo "    KUBECONFIG=$KUBECONFIG_OUT"
echo
echo "Try a fault:  ./scripts/fault.sh apply 09"
