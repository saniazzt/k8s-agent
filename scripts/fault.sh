#!/usr/bin/env bash
# fault.sh — inject / revert the RCA exercise faults in the rca-test namespace.
#
#   ./scripts/fault.sh list
#   ./scripts/fault.sh apply 06
#   ./scripts/fault.sh revert 06
#   ./scripts/fault.sh revert all
#
# The script MAY mutate the cluster (it is the operator's tool); the agent may not.
set -euo pipefail

K="${KUBECTL:-kubectl}"
NS="rca-test"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAULTS_DIR="$ROOT/k8s/faults"

patch_deploy()  { $K patch deploy demo-app -n "$NS" --type strategic --patch-file "$FAULTS_DIR/$1"; }
patch_cm()      { $K patch configmap demo-app-config -n "$NS" --type merge --patch-file "$FAULTS_DIR/$1"; }
patch_cm_revert(){ $K patch configmap demo-app-config -n "$NS" --type merge -p "$1"; }
patch_svc()     { $K patch svc demo-app -n "$NS" --type merge --patch-file "$FAULTS_DIR/$1"; }
rollout()       { $K rollout restart deploy/demo-app -n "$NS" >/dev/null; }

ls_faults() {
  cat <<'TXT'
 01  missing-env                 (easy) required ConfigMap env key removed
 02  oom-limit                   (easy) memory limit too low -> OOMKilled
 03  bad-image-tag               (easy) image tag does not exist
 04  unschedulable-requests      (easy) requests exceed node capacity
 05  missing-storageclass        (easy) PVC asks for an absent StorageClass
 06  service-selector-mismatch   (hard) Service selector no longer matches pods
 07  configmap-key-rename        (hard) ConfigMap key rename breaks a volume item
 08  networkpolicy-blocks-db     (hard) egress policy silently cuts DB traffic
 09  readiness-404               (hard) readiness probe hits a 404 path
 10  dns-broken                  (hard) pod DNS pointed at a dead nameserver
TXT
}

apply_fault() {
  case "$1" in
    01) patch_cm 01-missing-env.yaml; rollout ;;
    02) patch_deploy 02-oom-limit.yaml; rollout ;;
    03) patch_deploy 03-bad-image-tag.yaml; rollout ;;
    04) patch_deploy 04-unschedulable-requests.yaml; rollout ;;
    05) $K apply -f "$FAULTS_DIR/05-pvc.yaml"; patch_deploy 05-mount.yaml; rollout ;;
    06) patch_svc 06-service-selector-mismatch.yaml ;;
    07) patch_cm 07-configmap-key-rename.yaml; rollout ;;
    08) $K apply -f "$FAULTS_DIR/08-networkpolicy-blocks-db.yaml"; rollout ;;
    09) patch_deploy 09-readiness-404.yaml; rollout ;;
    10) patch_deploy 10-dns-broken.yaml; rollout ;;
    *) echo "unknown fault: $1"; ls_faults; exit 1 ;;
  esac
  echo "applied fault $1"
}

# Deterministic baseline: delete the workload and recreate it from the pristine
# base manifest. Per-field "revert" patches proved unreliable (JSON-merge/array
# semantics), so reverting always rebuilds the demo-app from source of truth.
restore_baseline() {
  $K delete networkpolicy demo-app-netpol -n "$NS" --ignore-not-found >/dev/null
  $K delete pvc demo-app-data -n "$NS" --ignore-not-found >/dev/null
  $K delete deploy demo-app -n "$NS" --ignore-not-found >/dev/null
  # ConfigMaps too: `apply` does not prune keys added by an earlier patch.
  $K delete configmap demo-app-config demo-app-code -n "$NS" --ignore-not-found >/dev/null
  $K apply -f "$ROOT/k8s/namespace.yaml" >/dev/null
  $K rollout status deploy/demo-app -n "$NS" --timeout=120s >/dev/null 2>&1 || true
}

revert_fault() {
  restore_baseline
  echo "reverted fault $1"
}

cmd="${1:-list}"
case "$cmd" in
  list) ls_faults ;;
  apply) apply_fault "${2:?usage: fault.sh apply <id>}" ;;
  revert)
    if [ "${2:-}" = "all" ]; then
      restore_baseline; echo "baseline restored"
    else
      revert_fault "${2:?usage: fault.sh revert <id|all>}"
    fi ;;
  *) ls_faults ;;
esac
