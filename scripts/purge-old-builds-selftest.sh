#!/usr/bin/env bash
#
# purge-old-builds-selftest.sh — prove scripts/purge-old-builds.sh's IN-USE detection and --delete
# refusals, in TEST MODE (a scratch root; the script never deletes in test mode).
# =============================================================================================
# Fixtures: three ditto copies of this checkout's team-signed build/sym Debug app under a scratch root,
# judged against a test app floor of 9.9 so all three are below-floor candidates.
#   1. a REAL process started by a relative path (ps shows "Contents/MacOS/…") inside bundle a is
#      resolved by the live proc_pidpath lister → a is IN-USE, b and c are not;
#   2. a process list holding ONLY the root daemon's line for bundle b (the app already quit) → b IN-USE;
#   3. a process list larger than 170 KB whose only match (bundle c) is the LAST line → c IN-USE;
#   4. an unresolvable process named like our helper → --delete REFUSED (list mode still works, warns);
#   5. a clean list + --delete → "would remove" all three, and all three still exist;
#   6. a pid that exited mid-scan (fed to the live lister) is skipped, so --delete is not refused.
# Exit 0 = all passed, 1 = a case failed, 77 = skipped (no team-signed build/sym Debug app).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET="${SCRIPT_DIR}/purge-old-builds.sh"
SRC="${CHECKOUT}/build/sym/Debug/Battery.app"
TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' "${CHECKOUT}/Signing.xcconfig" | head -1)"
info="$(codesign -dv "${SRC}" 2>&1 || true)"
if [ ! -d "${SRC}" ] || [[ "${info}" != *"TeamIdentifier=${TEAM}"* ]]; then
  echo "purge-old-builds-selftest: SKIP — no team-signed ${SRC}"; exit 77
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/purge-selftest.XXXXXX")"
SLEEPER_PID=""
trap '[ -n "${SLEEPER_PID}" ] && kill "${SLEEPER_PID}" 2>/dev/null; rm -rf "${WORK}"' EXIT
R="$(realpath "${WORK}")/root"
for b in a b c; do mkdir -p "${R}/${b}"; ditto "${SRC}" "${R}/${b}/Battery.app"; done
H="Contents/MacOS/com.example.batteryapp.energyhelper"

PASS=0; FAILED=0
ok()  { printf '  PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }
run() { # [--delete] — sets OUT and RC; PLIST (optional) is the fake process list
  if [ -n "${PLIST:-}" ]; then
    OUT="$(PURGE_TEST_ROOT="${R}" PURGE_TEST_MIN_APP=9.9 PURGE_TEST_PROCESS_LIST="${PLIST}" "${TARGET}" "$@" 2>&1)"
  else
    OUT="$(PURGE_TEST_ROOT="${R}" PURGE_TEST_MIN_APP=9.9 "${TARGET}" "$@" 2>&1)"
  fi
  RC=$?
}
status_of() { # bundle-letter → the STATUS column for it
  local line; line="$(printf '%s\n' "${OUT}" | awk -v p="${R}/$1/Battery.app" 'index($0, p) { print $1; exit }')"
  printf '%s' "${line}"
}

echo "purge-old-builds-selftest: ${TARGET}"

echo "1. a real relative-path process inside bundle a, resolved live"
cp /bin/sleep "${R}/a/Battery.app/Contents/MacOS/sleeper"
( cd "${R}/a/Battery.app" && exec Contents/MacOS/sleeper 120 ) &
SLEEPER_PID=$!
comm=""; n=0; while [ -z "${comm}" ] && [ ${n} -lt 200 ]; do comm="$(ps -p "${SLEEPER_PID}" -o comm= 2>/dev/null || true)"; n=$((n + 1)); done
PLIST="" run
if [[ "${comm}" == "Contents/MacOS/sleeper" ]] && [ "$(status_of a)" = "IN-USE" ] \
   && [ "$(status_of b)" != "IN-USE" ] && [ "$(status_of c)" != "IN-USE" ]; then
  ok "ps shows '${comm}' (relative); proc_pidpath resolves it → a IN-USE, b/c not"
else bad "comm='${comm}' a=$(status_of a) b=$(status_of b) c=$(status_of c)
${OUT}"; fi
kill "${SLEEPER_PID}" 2>/dev/null; wait "${SLEEPER_PID}" 2>/dev/null; SLEEPER_PID=""

echo "2. only the root daemon runs from bundle b (the app has quit)"
PLIST="${WORK}/daemon-only.txt"
printf '1\t/sbin/launchd\n5169\t%s/b/Battery.app/%s\n' "${R}" "${H}" > "${PLIST}"
run
if [ "$(status_of b)" = "IN-USE" ] && [ "$(status_of a)" != "IN-USE" ]; then ok "b IN-USE from the daemon line alone"
else bad "a=$(status_of a) b=$(status_of b)
${OUT}"; fi

echo "3. a process list over 170 KB, the only match on its last line"
PLIST="${WORK}/big.txt"
filler="$(printf 'x%.0s' $(seq 1 120))"
for i in $(seq 1 2000); do printf '%d\t/System/Library/PrivateFrameworks/Filler%04d.framework/Versions/A/%s\n' "$((10000 + i))" "${i}" "${filler}"; done > "${PLIST}"
printf '99999\t%s/c/Battery.app/Contents/MacOS/Battery\n' "${R}" >> "${PLIST}"
size="$(stat -f %z "${PLIST}")"
run
if [ "${size}" -gt 174080 ] && [ "$(status_of c)" = "IN-USE" ]; then ok "list is ${size} bytes; c IN-USE"
else bad "size=${size} c=$(status_of c)
${OUT}"; fi

echo "4. an unresolvable process named like our helper"
PLIST="${WORK}/unresolved.txt"
printf '1\t/sbin/launchd\n777\t?\tcom.example.batteryapp.energyhe\n' > "${PLIST}"
run; list_rc=${RC}; list_out="${OUT}"
run --delete
if [ "${list_rc}" -eq 0 ] && [[ "${list_out}" == *"could not be resolved"* ]] && [ "${RC}" -ne 0 ] \
   && [[ "${OUT}" == *"refusing --delete"* ]] && [[ "${OUT}" != *"would remove"* ]]; then
  ok "list mode warns (rc 0); --delete refused (rc ${RC})"
else bad "list_rc=${list_rc} delete_rc=${RC}
${OUT}"; fi

echo "5. clean list + --delete in test mode removes nothing"
PLIST="${WORK}/clean.txt"; printf '1\t/sbin/launchd\n' > "${PLIST}"
run --delete
would="$(printf '%s\n' "${OUT}" | awk '/TEST MODE: would remove/ { n++ } END { print n + 0 }')"
if [ "${RC}" -eq 0 ] && [ "${would}" -eq 3 ] && [ -d "${R}/a/Battery.app" ] && [ -d "${R}/b/Battery.app" ] && [ -d "${R}/c/Battery.app" ]; then
  ok "would remove 3; all 3 still exist"
else bad "rc=${RC} would=${would}
${OUT}"; fi

echo "6. a pid that exited mid-scan (path and name unreadable, kill -0 → ESRCH) does not block --delete"
/usr/bin/true & dead=$!; wait "${dead}" 2>/dev/null
if kill -0 "${dead}" 2>/dev/null; then
  bad "pid ${dead} is unexpectedly alive (reused?) — cannot run case 6"
else
  PLIST=""
  OUT="$(PURGE_TEST_ROOT="${R}" PURGE_TEST_MIN_APP=9.9 PURGE_TEST_EXTRA_PIDS="${dead}" "${TARGET}" --delete 2>&1)"; RC=$?
  would="$(printf '%s\n' "${OUT}" | awk '/TEST MODE: would remove/ { n++ } END { print n + 0 }')"
  if [ "${RC}" -eq 0 ] && [ "${would}" -eq 3 ] && [[ "${OUT}" != *"could not be resolved"* ]]; then
    ok "exited pid ${dead} skipped; --delete proceeds (would remove 3)"
  else bad "rc=${RC} would=${would}
${OUT}"; fi
fi

echo "purge-old-builds-selftest: ${PASS} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
