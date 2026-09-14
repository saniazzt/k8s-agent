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
FAULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../k8s/faults" && pwd)"

patch_deploy()  { $K patch deploy demo-app -n "$NS" --type merge --patch-file "$FAULTS_DIR/$1"; }
patch_cm()      { $K patch configmap demo-app-config -n "$NS" --type merge --patch-file "$FAULTS_DIR/$1"; }
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

revert_fault() {
  case "$1" in
    01) $K patch configmap demo-app-config -n "$NS" --type merge -p '{"data":{"DB_HOST":"demo-db"}}'; rollout ;;
    02) $K patch deploy demo-app -n "$NS" --type merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"20m","memory":"48Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}}}'; rollout ;;
    03) $K patch deploy demo-app -n "$NS" --type merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","image":"docker.io/library/python:3.11-alpine"}]}}}}'; rollout ;;
    04) $K patch deploy demo-app -n "$NS" --type merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"20m","memory":"48Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}}}'; rollout ;;
    05) $K delete pvc demo-app-data -n "$NS" --ignore-not-found
        $K patch deploy demo-app -n "$NS" --type json -p '[{"op":"remove","path":"/spec/template/spec/volumes/2"}]' 2>/dev/null || true
        $K get deploy demo-app -n "$NS" -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
spec=d['spec']['template']['spec']
spec['volumes']=[v for v in spec.get('volumes',[]) if v['name']!='data']
for c in spec['containers']:
    c['volumeMounts']=[m for m in c.get('volumeMounts',[]) if m['name']!='data']
print(json.dumps(d['spec']['template']['spec']))
" > /tmp/rca-volumes.json
        $K patch deploy demo-app -n "$NS" --type merge --patch-file /tmp/rca-volumes.json; rollout ;;
    06) $K patch svc demo-app -n "$NS" --type merge -p '{"spec":{"selector":{"app":"demo-app"}}}' ;;
    07) $K patch configmap demo-app-config -n "$NS" --type merge -p '{"data":{"LOG_LEVEL":"info","LOG_LEVEL_NEW":null}}'; rollout ;;
    08) $K delete networkpolicy demo-app-netpol -n "$NS" --ignore-not-found; rollout ;;
    09) $K patch deploy demo-app -n "$NS" --type merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","readinessProbe":{"httpGet":{"path":"/ready","port":8080}}}]}}}}'; rollout ;;
    10) $K patch deploy demo-app -n "$NS" --type json -p '[{"op":"remove","path":"/spec/template/spec/dnsConfig"}]' 2>/dev/null || true; rollout ;;
    *) echo "unknown fault: $1"; exit 1 ;;
  esac
  echo "reverted fault $1"
}

cmd="${1:-list}"
case "$cmd" in
  list) ls_faults ;;
  apply) apply_fault "${2:?usage: fault.sh apply <id>}" ;;
  revert)
    if [ "${2:-}" = "all" ]; then
      for id in 01 02 03 04 05 06 07 08 09 10; do revert_fault "$id" || true; done
      $K delete networkpolicy demo-app-netpol -n "$NS" --ignore-not-found
      $K delete pvc demo-app-data -n "$NS" --ignore-not-found
    else
      revert_fault "${2:?usage: fault.sh revert <id|all>}"
    fi ;;
  *) ls_faults ;;
esac
