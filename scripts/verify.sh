#!/usr/bin/env bash
# Sanity-check the Swift app and the exact bundled email-cli contract the
# release app will run. This intentionally avoids PATH email-cli: agents often
# have an older cargo/homebrew binary installed, while Minimail ships its own.
set -euo pipefail

cd "$(dirname "$0")/.."

pass=0
fail=0
fail_item() { echo "  ✗ $1"; fail=$((fail + 1)); }
pass_item() { echo "  ✓ $1"; pass=$((pass + 1)); }

run_json() {
  local label="$1"; shift
  local out rc status
  set +e
  out="$("${CLI}" "$@" --json 2>&1)"
  rc=$?
  set -e
  if [ ${rc} -ne 0 ]; then
    fail_item "${label}: exit ${rc}: ${out:0:160}"
    return 1
  fi
  status=$(printf '%s' "${out}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || true)
  if [ "${status}" != "success" ]; then
    fail_item "${label}: status=${status}"
    return 1
  fi
  pass_item "${label}"
}

echo "▸ Swift tests"
swift test
pass_item "swift test"

echo
echo "▸ Release bundle"
./scripts/build-app.sh release
CLI=".build/Minimail.app/Contents/MacOS/email-cli"
if [ ! -x "${CLI}" ]; then
  echo "✗ bundled email-cli missing: ${CLI}" >&2
  exit 1
fi
pass_item "bundled email-cli exists"

echo
echo "▸ Bundled CLI contract"
version="$("${CLI}" --version)"
if [[ "${version}" == email-cli* ]] || printf '%s' "${version}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('usage','').startswith('email-cli'))" 2>/dev/null | grep -q True; then
  pass_item "version"
else
  fail_item "version output unexpected: ${version}"
fi
if "${CLI}" signature set --help | grep -q -- "--html"; then
  pass_item "signature set supports --html"
else
  fail_item "signature set missing --html"
fi
if "${CLI}" draft create --help | grep -q -- "--reply-to-msg"; then
  pass_item "draft create supports --reply-to-msg"
else
  fail_item "draft create missing --reply-to-msg"
fi

echo
echo "▸ Local configured-data smoke tests"
if run_json "account list" account list; then
  run_json "inbox stats" inbox stats || true
  run_json "inbox list" inbox list --limit 2 || true
else
  echo "  - skipped mailbox smoke tests: no configured account or invalid key"
fi

echo
echo "─────────────────────────"
printf "pass %d · fail %d\n" "${pass}" "${fail}"
exit $((fail > 0 ? 1 : 0))
