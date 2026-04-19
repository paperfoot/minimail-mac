#!/usr/bin/env bash
# Sanity-check the Swift/CLI integration. Runs every email-cli call Minimail
# makes, parses each response as the Swift model's JSON shape, reports pass/fail.
# Catches decode regressions before the user sees them in the popover.
set -u

cd "$(dirname "$0")/.."

pass=0; fail=0
fail_item() { echo "  ✗ $1"; fail=$((fail+1)); }
pass_item() { echo "  ✓ $1"; pass=$((pass+1)); }

echo "▸ cargo? swift build"
if ! swift build -c release --quiet 2>&1 | tail -5; then
  echo "✗ swift build failed"
  exit 1
fi

echo
echo "▸ email-cli in PATH"
if command -v email-cli >/dev/null; then
  pass_item "email-cli found at $(command -v email-cli)"
else
  fail_item "email-cli not in PATH"
fi

echo
echo "▸ CLI contract checks"

run_json() {
  local label="$1"; shift
  local out
  out="$(email-cli "$@" --json 2>&1)"
  local rc=$?
  if [ $rc -ne 0 ]; then
    fail_item "$label: exit $rc: ${out:0:120}"
    return 1
  fi
  local status
  status=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
  if [ "$status" != "success" ]; then
    fail_item "$label: status=$status"
    return 1
  fi
  # Check required fields per call
  case "$label" in
    "account list")
      printf '%s' "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
assert isinstance(d, list) and len(d) > 0, 'expected non-empty list'
for a in d:
    assert 'email' in a and 'profile_name' in a, f'missing fields in {a}'
    assert isinstance(a.get('is_default'), bool) or a.get('is_default') is None
" 2>&1 && pass_item "$label (shape ok, $(printf '%s' "$out" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['data']))") accounts)" || fail_item "$label (shape drift)"
      ;;
    "inbox list")
      printf '%s' "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
assert 'messages' in d, 'missing messages'
for m in d['messages']:
    assert isinstance(m.get('is_read'), bool) or m.get('is_read') is None, f'is_read not bool: {type(m.get(\"is_read\"))}'
    assert isinstance(m.get('archived'), bool) or m.get('archived') is None, f'archived not bool: {type(m.get(\"archived\"))}'
    assert m.get('direction') in ('sent','received'), f'direction: {m.get(\"direction\")}'
    assert 'id' in m and 'from_addr' in m, 'required fields'
" 2>&1 && pass_item "$label (shape ok)" || fail_item "$label (shape drift)"
      ;;
    "inbox stats")
      printf '%s' "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
for k in ('inbox','unread','sent','archived','total'):
    assert k in d, f'missing {k}'
" 2>&1 && pass_item "$label (shape ok)" || fail_item "$label (shape drift)"
      ;;
    "inbox read")
      printf '%s' "$out" | python3 -c "
import json, sys
m = json.load(sys.stdin)['data']
assert isinstance(m.get('is_read'), bool) or m.get('is_read') is None
" 2>&1 && pass_item "$label (shape ok, id=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])'))" || fail_item "$label (shape drift)"
      ;;
  esac
}

run_json "account list" account list
run_json "inbox list" inbox list --limit 2
run_json "inbox stats" inbox stats

# Need a real ID for inbox read
ID=$(email-cli inbox list --json --limit 1 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d['messages'][0]['id'] if d['messages'] else '')")
if [ -n "$ID" ]; then
  run_json "inbox read" inbox read "$ID" --mark-read false
fi

echo
echo "─────────────────────────"
printf "pass %d · fail %d\n" "$pass" "$fail"
exit $((fail > 0 ? 1 : 0))
