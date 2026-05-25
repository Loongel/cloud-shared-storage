#!/bin/sh
set -eu

SMOKE=${SMOKE:-/tmp/cs-storage-production-readiness}
IMAGE=${IMAGE:-cs-storage:hd01-smoke}
PROBE_IMAGE=${PROBE_IMAGE:-alpine:3.20}

RUN_PATH_PREFLIGHT=${RUN_PATH_PREFLIGHT:-1}
RUN_CLUSTER_PREFLIGHT=${RUN_CLUSTER_PREFLIGHT:-1}
RUN_SECRETS_PREFLIGHT=${RUN_SECRETS_PREFLIGHT:-1}
RUN_STACK_PLAN=${RUN_STACK_PLAN:-1}
RUN_ACCEPTANCE_AUDIT=${RUN_ACCEPTANCE_AUDIT:-1}

rm -rf "$SMOKE"
mkdir -p "$SMOKE"

issues=0

run_gate() {
  name=$1
  shift
  log="$SMOKE/$name.log"
  echo "READINESS_GATE_RUN name=$name"
  set +e
  "$@" > "$log" 2>&1
  rc=$?
  set -e
  cat "$log"
  echo "READINESS_GATE_RESULT name=$name rc=$rc log=$log"
  if test "$rc" -ne 0; then
    issues=$((issues + 1))
  fi
  return 0
}

if test "$RUN_ACCEPTANCE_AUDIT" = "1"; then
  run_gate acceptance_audit ./scripts/hd01-acceptance-audit.sh
  if grep -q "ACCEPTANCE_AUDIT_INCOMPLETE" "$SMOKE/acceptance_audit.log"; then
    issues=$((issues + 1))
  fi
fi

if test "$RUN_PATH_PREFLIGHT" = "1"; then
  run_gate production_path_preflight env IMAGE="$PROBE_IMAGE" STRICT=1 ./scripts/hd01-production-path-preflight.sh
fi

if test "$RUN_CLUSTER_PREFLIGHT" = "1"; then
  run_gate cluster_preflight env IMAGE="$PROBE_IMAGE" STRICT=1 ./scripts/hd01-cluster-preflight.sh
fi

if test "$RUN_SECRETS_PREFLIGHT" = "1"; then
  run_gate production_secrets_preflight env IMAGE="$PROBE_IMAGE" STRICT=1 ./scripts/hd01-production-secrets-preflight.sh
fi

if test "$RUN_STACK_PLAN" = "1"; then
  run_gate production_stack_plan_dummy env IMAGE="$IMAGE" DUMMY=1 ./scripts/hd01-production-stack-plan.sh
  run_gate production_stack_plan_real env IMAGE="$IMAGE" DUMMY=0 ./scripts/hd01-production-stack-plan.sh
fi

if test "$issues" -gt 0; then
  echo "PRODUCTION_READINESS_GATE_NOT_READY issues=$issues out=$SMOKE"
  exit 1
fi

echo "PRODUCTION_READINESS_GATE_OK out=$SMOKE"
