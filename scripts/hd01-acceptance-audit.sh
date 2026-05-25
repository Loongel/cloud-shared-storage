#!/bin/sh
set -eu

MATRIX=${MATRIX:-docs/acceptance-matrix.tsv}
README=${README:-README.md}
OUT=${OUT:-/tmp/cs-storage-acceptance-audit.tsv}

if ! test -s "$MATRIX"; then
  echo "ACCEPTANCE_AUDIT_ERROR missing_matrix=$MATRIX"
  exit 1
fi
if ! test -s "$README"; then
  echo "ACCEPTANCE_AUDIT_ERROR missing_readme=$README"
  exit 1
fi

pass=0
partial=0
pending=0
blocked=0
fail=0
total=0
: > "$OUT"
printf 'id\texpected_status\taudit_status\tmissing_tokens\trequirement\tgap\n' >> "$OUT"

tail -n +2 "$MATRIX" | while IFS= read -r line; do
  test -n "$line" || continue
  id=$(printf '%s\n' "$line" | cut -f1)
  status=$(printf '%s\n' "$line" | cut -f2)
  requirement=$(printf '%s\n' "$line" | cut -f3)
  evidence=$(printf '%s\n' "$line" | cut -f4)
  gap=$(printf '%s\n' "$line" | cut -f5-)
  total=$((total + 1))
  missing=""
  old_ifs=$IFS
  IFS='|'
  # shellcheck disable=SC2086
  for token in $evidence; do
    IFS=$old_ifs
    if test -n "$token" && ! grep -F -- "$token" "$README" >/dev/null 2>&1; then
      if test -z "$missing"; then
        missing="$token"
      else
        missing="$missing | $token"
      fi
    fi
    IFS='|'
  done
  IFS=$old_ifs
  if test -n "$missing"; then
    audit="missing-evidence"
    fail=$((fail + 1))
  else
    audit="$status"
    case "$status" in
      pass) pass=$((pass + 1)) ;;
      partial) partial=$((partial + 1)) ;;
      pending) pending=$((pending + 1)) ;;
      blocked-lab) blocked=$((blocked + 1)) ;;
      *) fail=$((fail + 1)); audit="unknown-status:$status" ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$status" "$audit" "$missing" "$requirement" "$gap" >> "$OUT"
  printf '%s\t%s\t%s\t%s\t%s\n' "$pass" "$partial" "$pending" "$blocked" "$fail" > "$OUT.counts"
  printf '%s\n' "$total" > "$OUT.total"
done
if test -s "$OUT.counts"; then
  set -- $(cat "$OUT.counts")
  pass=$1
  partial=$2
  pending=$3
  blocked=$4
  fail=$5
fi
if test -s "$OUT.total"; then
  total=$(cat "$OUT.total")
fi
rm -f "$OUT.counts" "$OUT.total"

cat "$OUT"
if test "$fail" -gt 0; then
  echo "ACCEPTANCE_AUDIT_FAIL total=$total pass=$pass partial=$partial pending=$pending blocked_lab=$blocked missing_evidence=$fail out=$OUT"
  exit 1
fi
if test "$partial" -gt 0 || test "$pending" -gt 0 || test "$blocked" -gt 0; then
  echo "ACCEPTANCE_AUDIT_INCOMPLETE total=$total pass=$pass partial=$partial pending=$pending blocked_lab=$blocked missing_evidence=0 out=$OUT"
  exit 0
fi

echo "ACCEPTANCE_AUDIT_COMPLETE total=$total pass=$pass out=$OUT"
