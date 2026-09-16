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
signature_help="$("${CLI}" signature set --help)"
if [[ "${signature_help}" == *"--html"* ]]; then
  pass_item "signature set supports --html"
else
  fail_item "signature set missing --html"
fi
draft_help="$("${CLI}" draft create --help)"
if [[ "${draft_help}" == *"--reply-to-msg"* ]]; then
  pass_item "draft create supports --reply-to-msg"
else
  fail_item "draft create missing --reply-to-msg"
fi
draft_edit_help="$("${CLI}" draft edit --help)"
for required_flag in --reply-to --clear-schedule --clear-html; do
  if [[ "${draft_edit_help}" == *"${required_flag}"* ]]; then
    pass_item "draft edit supports ${required_flag}"
  else
    fail_item "draft edit missing ${required_flag}"
  fi
done

echo
echo "▸ Hermetic bundled CLI smoke tests"
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/minimail-verify.XXXXXX")"
trap 'rm -rf "${SMOKE_DIR}"' EXIT
SMOKE_DB="${SMOKE_DIR}/email-cli.db"
run_json "account list" --db "${SMOKE_DB}" account list || true
run_json "inbox stats" --db "${SMOKE_DB}" inbox stats || true
run_json "inbox list" --db "${SMOKE_DB}" inbox list --limit 2 || true
python3 - "${SMOKE_DB}" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("INSERT INTO profiles (name, api_key) VALUES ('smoke', 'offline-test-key')")
    db.execute("INSERT INTO accounts (email, profile_name, display_name, signature, is_default) VALUES ('first@example.test', 'smoke', 'Before', 'Keep signature', 1)")
    db.execute("INSERT INTO accounts (email, profile_name, is_default) VALUES ('second@example.test', 'smoke', 0)")
PY
run_json "account edit works offline with unchanged profile" --db "${SMOKE_DB}" account edit first@example.test --name After --profile smoke || true
run_json "account remove and reassign default" --db "${SMOKE_DB}" account remove first@example.test --yes || true
if python3 - "${SMOKE_DB}" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    assert db.execute("SELECT email FROM accounts WHERE is_default = 1").fetchone() == ('second@example.test',)
PY
then pass_item "removed default replaced deterministically"; else fail_item "replacement default"; fi
run_json "remove final account" --db "${SMOKE_DB}" account remove second@example.test --yes || true
run_json "remove unused profile" --db "${SMOKE_DB}" profile remove smoke --yes || true

echo
echo "─────────────────────────"
printf "pass %d · fail %d\n" "${pass}" "${fail}"
exit $((fail > 0 ? 1 : 0))
