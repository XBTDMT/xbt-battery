#!/usr/bin/env bash
#
# install-release-selftest.sh — exercise scripts/install-release.sh's refusal and rollback logic
# WITHOUT root and without touching /Applications.
# =============================================================================================
# The REAL script runs, aimed at a scratch BATTERY_INSTALL_DEST, with a fake `sudo` first on PATH
# that logs its arguments and then runs the command as YOU (so nothing ever gets root), plus a fake
# `pgrep` that says Battery is or is not running. What this can prove without root:
#   A. a planted symlink at DEST is refused before sudo is ever called;
#   B. a DEST holding some other app is refused before sudo is ever called;
#   C. Battery running is refused before sudo is ever called;
#   D. a stage dir that is not root-owned (which is what you get without real root) is refused, the
#      existing DEST is left byte-for-byte untouched, and the stage dir is cleaned up.
# The root-only steps after D (chown, the staged verify, the renames, the EXIT-trap restore) need
# real root and are covered by reading, not by this harness.
#
# Needs a verified Release build at build/sym-release (scripts/install-release.sh, no flags).
# Exit 0 = all cases passed, 1 = a case failed, 77 = skipped (no verified Release build).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/install-release.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-release-selftest.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
FAKEBIN="${WORK}/bin"; LOG="${WORK}/sudo.log"; mkdir -p "${FAKEBIN}"

cat > "${FAKEBIN}/sudo" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "${LOG}"
[ "\${1:-}" = "-v" ] && exit 0
exec "\$@"
EOF
cat > "${FAKEBIN}/pgrep" <<'EOF'
#!/bin/bash
[ "${FAKE_BATTERY_RUNNING:-0}" = "1" ]
EOF
chmod +x "${FAKEBIN}/sudo" "${FAKEBIN}/pgrep"

PASS=0; FAILED=0
ok()  { printf '  PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }

if ! "${TARGET}" --skip-build >/dev/null 2>&1; then
  echo "install-release-selftest: SKIP — no verified Release build (run scripts/install-release.sh first)"
  exit 77
fi

# run_case DEST [env...] — runs the real script with --install --skip-build; sets OUT and RC.
run_case() {
  local dest="$1"; shift
  : > "${LOG}"
  OUT="$(env "$@" PATH="${FAKEBIN}:${PATH}" BATTERY_INSTALL_DEST="${dest}" "${TARGET}" --install --skip-build 2>&1)"
  RC=$?
}
mkapp() { # dir bundle-id
  mkdir -p "$1/Contents"
  /usr/bin/plutil -create xml1 "$1/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
  echo "previous install" > "$1/Contents/marker"
}

echo "install-release-selftest: running ${TARGET}"

echo "A. planted symlink at DEST"
mkdir -p "${WORK}/A/attacker"; ln -s "${WORK}/A/attacker" "${WORK}/A/Battery.app"
run_case "${WORK}/A/Battery.app"
if [ "${RC}" -ne 0 ] && [[ "${OUT}" == *"symbolic link"* ]] && [ ! -s "${LOG}" ] && [ -z "$(ls -A "${WORK}/A/attacker")" ]; then
  ok "refused, sudo never called, nothing written through the link"
else bad "rc=${RC} sudo-calls=$(wc -l < "${LOG}") out=${OUT}"; fi

echo "B. DEST is a different app"
mkapp "${WORK}/B/Battery.app" "com.example.other"
run_case "${WORK}/B/Battery.app"
if [ "${RC}" -ne 0 ] && [[ "${OUT}" == *"refusing to replace it"* ]] && [ ! -s "${LOG}" ]; then
  ok "refused, sudo never called"
else bad "rc=${RC} out=${OUT}"; fi

echo "C. Battery is running"
mkdir -p "${WORK}/C"
run_case "${WORK}/C/Battery.app" FAKE_BATTERY_RUNNING=1
if [ "${RC}" -ne 0 ] && [[ "${OUT}" == *"Battery is running"* ]] && [ ! -s "${LOG}" ]; then
  ok "refused, sudo never called"
else bad "rc=${RC} out=${OUT}"; fi

echo "   (precondition for D: sudo on the test PATH is the fake)"
resolved_sudo="$(PATH="${FAKEBIN}:${PATH}" /bin/bash -c 'command -v sudo')"
if [ "${resolved_sudo}" != "${FAKEBIN}/sudo" ]; then
  bad "sudo resolves to '${resolved_sudo}', not the fake — refusing to run case D"
  echo "install-release-selftest: ${PASS} passed, ${FAILED} failed"; exit 1
fi
ok "sudo resolves to the fake (${resolved_sudo})"

echo "D. stage dir not root-owned (no real root) — previous install must survive untouched"
mkapp "${WORK}/D/Battery.app" "com.example.batteryapp"
before_sum="$(find "${WORK}/D" -type f -exec shasum {} + | sort)"
stages_before="$(ls -d /private/var/tmp/battery-install.* 2>/dev/null | sort)"
run_case "${WORK}/D/Battery.app"
after_sum="$(find "${WORK}/D" -type f -exec shasum {} + | sort)"
stages_after="$(ls -d /private/var/tmp/battery-install.* 2>/dev/null | sort)"
if [ "${RC}" -ne 0 ] && [[ "${OUT}" == *"is not root-owned"* ]] && [ "${before_sum}" = "${after_sum}" ] \
   && [ "${stages_before}" = "${stages_after}" ] && grep -q "mktemp -d /private/var/tmp/battery-install." "${LOG}"; then
  ok "refused after an unpredictable mktemp stage, DEST unchanged, stage dir removed"
else bad "rc=${RC} same-dest=$([ "${before_sum}" = "${after_sum}" ] && echo y || echo n) stages-left=$([ "${stages_before}" = "${stages_after}" ] && echo n || echo y) out=${OUT}"; fi

echo "E. an overridden DEST with the REAL sudo (/usr/bin) is refused"
# Only a fake pgrep that says Battery IS running is on PATH here, so sudo resolves to /usr/bin/sudo.
# The DEST guard runs before the pgrep check, which runs before any sudo: if the guard were broken,
# the run would still stop at "Battery is running" without ever calling sudo — and this case fails.
PGREPBIN="${WORK}/pgrep-only"; mkdir -p "${PGREPBIN}"; cp "${FAKEBIN}/pgrep" "${PGREPBIN}/pgrep"
mkapp "${WORK}/E/Battery.app" "com.example.batteryapp"
OUT="$(env FAKE_BATTERY_RUNNING=1 PATH="${PGREPBIN}:${PATH}" BATTERY_INSTALL_DEST="${WORK}/E/Battery.app" "${TARGET}" --install --skip-build 2>&1)"; RC=$?
if [ "${RC}" -ne 0 ] && [[ "${OUT}" == *"only for install-release-selftest.sh"* ]]; then
  ok "refused by the DEST guard (sudo resolves to $(command -v sudo))"
else bad "rc=${RC} out=${OUT}"; fi

echo "install-release-selftest: ${PASS} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
