#!/usr/bin/env bash
#
# install-release.sh — build the RELEASE Battery.app, prove it is safe to pair with the root helper, and
# (only with --install) put it in /Applications as a ROOT-OWNED bundle.
# =============================================================================================
# WHY (security posture, 2026-10-15): the energy helper runs as root and launchd runs it from INSIDE the
# app bundle (helper/EnergyHelper.plist BundleProgram = Contents/MacOS/com.example.batteryapp.energyhelper).
# A bundle the logged-in user can write — anything under build/, or a drag-copy into /Applications, which
# leaves the files owned by that user — lets any same-user process swap the binary launchd will run as
# root. This script installs a copy owned by root:wheel with no group/other write anywhere in it.
#
# The client side is closed in the code, not here: the helper's peer pin
# (BatteryAppIDs.appRequirement, shared/DesignatedRequirement.swift) refuses any app below the app floor
# or carrying get-task-allow / allow-dyld-environment-variables / disable-library-validation. This script
# re-checks those properties on the bundle it is about to install, so a misconfigured build never lands.
#
# Usage:
#   scripts/install-release.sh              build Release into build/sym-release + verify. No sudo, no
#                                           install, nothing outside this repo changes.
#   scripts/install-release.sh --install    the same, then install to /Applications/Battery.app (asks for
#                                           an admin password via sudo).
#   --skip-build                            verify (and with --install, install) the existing
#                                           build/sym-release product instead of rebuilding.
#
# It NEVER launches the app, never registers or bounces the daemon, never edits Signing.xcconfig, and
# never removes an /Applications/Battery.app whose bundle id is not com.example.batteryapp.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

BUNDLE_ID="com.example.batteryapp"
HELPER_ID="com.example.batteryapp.energyhelper"
SYMROOT_RELEASE="${REPO_ROOT}/build/sym-release"
APP="${SYMROOT_RELEASE}/Release/Battery.app"
# BATTERY_INSTALL_DEST exists ONLY so scripts/install-release-selftest.sh can aim the refusal paths at
# a scratch directory; it must still end in /Battery.app. Real installs leave it unset.
DEST="${BATTERY_INSTALL_DEST:-/Applications/Battery.app}"
case "${DEST}" in /*/Battery.app) ;; *) printf 'install-release: FAIL: DEST must be an absolute path ending in /Battery.app\n' >&2; exit 2 ;; esac
# Root-owned, sticky, on the same APFS volume as /Applications (both firmlink into the Data volume —
# measured: same st_dev, and one rename(2) between them keeps the inode). A root-made mktemp dir here
# cannot be renamed, replaced or written by the user (sticky bit + root owner).
STAGE_BASE="/private/var/tmp"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

INSTALL=0
BUILD=1
for arg in "$@"; do
  case "${arg}" in
    --install)    INSTALL=1 ;;
    --skip-build) BUILD=0 ;;
    -h|--help)    sed -n '2,27p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'install-release: unknown argument %s (see --help)\n' "${arg}" >&2; exit 2 ;;
  esac
done

say()  { printf 'install-release: %s\n' "$*"; }
fail() { printf 'install-release: FAIL: %s\n' "$*" >&2; exit 1; }

# ---- 1. build ---------------------------------------------------------------------------------
if [ "${BUILD}" -eq 1 ]; then
  command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found (brew install xcodegen)"
  say "generating the Xcode project (DEVELOPER_DIR=${DEVELOPER_DIR})"
  xcodegen generate >/dev/null
  mkdir -p "${SYMROOT_RELEASE}"
  LOG="${SYMROOT_RELEASE}/install-release-build.log"
  say "building Release → ${APP} (log: ${LOG})"
  if ! xcodebuild -scheme Battery -configuration Release SYMROOT="${SYMROOT_RELEASE}" build >"${LOG}" 2>&1; then
    tail -30 "${LOG}" >&2
    fail "Release build failed — see ${LOG}"
  fi
fi
[ -d "${APP}" ] || fail "no Release build at ${APP} (run without --skip-build)"

# ---- 2. verify --------------------------------------------------------------------------------
# verify_bundle PATH — every property the root helper's trust depends on. Fails the script on any miss.
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
src_const() { sed -n "s/.*static let $1 = \"\\(.*\\)\".*/\\1/p" "${REPO_ROOT}/shared/DesignatedRequirement.swift" | head -1; }

MIN_APP="$(src_const minAppShortVersion)"
MIN_HELPER="$(src_const minHelperShortVersion)"
[ -n "${MIN_APP}" ] && [ -n "${MIN_HELPER}" ] || fail "could not read the version floors from shared/DesignatedRequirement.swift"
INJECTION_KEYS=(
  com.apple.security.get-task-allow
  com.apple.security.cs.allow-dyld-environment-variables
  com.apple.security.cs.disable-library-validation
)

verify_bundle() {
  local app="$1" helper="$1/Contents/MacOS/${HELPER_ID}"
  say "verifying ${app}"

  [ "$(plist_get "${app}" CFBundleIdentifier)" = "${BUNDLE_ID}" ] || fail "bundle id is not ${BUNDLE_ID}"
  local team; team="$(plist_get "${app}" TeamID)"
  [ -n "${team}" ] || fail "TeamID missing from the app's Info.plist"
  [ -x "${helper}" ] || fail "embedded helper missing at ${helper}"

  codesign --verify --deep --strict "${app}" || fail "codesign --verify --deep --strict failed"

  # Each check captures output first and matches in the shell: under `set -o pipefail`, `cmd | grep -q`
  # can report FAILURE on a match (grep exits early, the writer takes SIGPIPE), hiding what it found.
  local bin info
  for bin in "${app}" "${helper}"; do
    info="$(codesign -dv "${bin}" 2>&1 || true)"
    [[ "${info}" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || fail "hardened runtime is OFF on ${bin}"
  done

  # Stricter than the pin on purpose: the pin accepts an explicit `false`, but no build of ours carries
  # these keys at all, so any appearance means the build setting changed.
  local ents key
  ents="$(codesign -d --entitlements - --xml "${app}" 2>/dev/null || true)"
  for key in "${INJECTION_KEYS[@]}"; do
    if [[ "${ents}" == *"<key>${key}</key>"* ]]; then
      fail "the app is signed with ${key} — the helper would refuse it (CODE_SIGN_INJECT_BASE_ENTITLEMENTS must be NO)"
    fi
  done

  local f
  for f in "${app}/Contents/MacOS/"*; do
    case "$(basename "${f}")" in
      *.debug.dylib|__preview.dylib) fail "debug / preview dylib present ($(basename "${f}")) — this is not a Release build" ;;
    esac
  done

  # The exact pins, evaluated by the Security framework on this bundle. Same shape as
  # BatteryAppIDs.appRequirement / helperRequirement (pinned verbatim in tests/SharedTests.swift).
  local excl="" k
  for k in "${INJECTION_KEYS[@]}"; do excl="${excl} and !(entitlement[\"${k}\"] exists)"; done
  local app_req="identifier \"${BUNDLE_ID}\" and anchor apple generic and certificate leaf[subject.OU] = \"${team}\" and info[CFBundleShortVersionString] >= \"${MIN_APP}\"${excl}"
  local helper_req="identifier \"${HELPER_ID}\" and anchor apple generic and certificate leaf[subject.OU] = \"${team}\" and info[CFBundleShortVersionString] >= \"${MIN_HELPER}\""
  codesign --verify -R="${app_req}" "${app}" || fail "the app does not satisfy the helper's client pin: ${app_req}"
  codesign --verify -R="${helper_req}" "${helper}" || fail "the helper does not satisfy the app's helper pin: ${helper_req}"

  "${REPO_ROOT}/scripts/smc-dead-gate.sh" "${helper}" "${REPO_ROOT}/project.yml" >/dev/null \
    || fail "SMC-DEAD gate failed on ${helper} (run it directly for the table)"

  say "  ok: signature, hardened runtime, no injection entitlements, no debug dylibs, both pins, SMC-DEAD"
}

# A PRE-check only: build/sym-release is writable by you, so it could change after this. The binding
# verify runs again on the root-owned staged copy, before anything is moved into place.
verify_bundle "${APP}"

if [ "${INSTALL}" -eq 0 ]; then
  say "verified. Nothing was installed. To install a root-owned copy to ${DEST}:"
  say "  scripts/install-release.sh --install --skip-build"
  exit 0
fi

# ---- 3. install (root-owned) ------------------------------------------------------------------
# Threat: /Applications is writable by the admin group, so a same-user process can plant or swap
# entries there at any moment, and build/sym-release is writable outright. So: (1) stage in a
# root-only, unpredictable directory, never at a guessable path; (2) run the FULL verify on the staged
# copy AFTER it is root-owned (nothing can change it from then on); (3) move with rename(2), which
# refuses a planted symlink (ENOTDIR) or a non-empty directory instead of writing through or into it
# the way `mv` does (measured); (4) keep the previous install until the new one passes its post-install
# verify, and put it back from the EXIT trap on any failure.
[ "$(id -u)" -ne 0 ] || fail "run this as yourself, not as root — it calls sudo only for the install steps"

# BATTERY_INSTALL_DEST is for install-release-selftest.sh, which puts a fake sudo first on PATH. With
# the real sudo, an overridden DEST would be a genuine root install into some other (possibly
# user-writable) folder — exactly what this script exists to prevent — so refuse it.
if [ "${DEST}" != "/Applications/Battery.app" ]; then
  # `type -P` resolves the PATH executable even if a shell function shadows the name. It counts as the
  # real sudo if it is setuid, or the same file as /usr/bin/sudo (covers //usr/bin/sudo and symlinks).
  # Not found also refuses.
  sudo_path="$(type -P sudo || true)"
  if [ -z "${sudo_path}" ] || [ -u "${sudo_path}" ] || [ "${sudo_path}" -ef /usr/bin/sudo ]; then
    fail "BATTERY_INSTALL_DEST (${DEST}) is only for install-release-selftest.sh; a real install goes to /Applications/Battery.app"
  fi
fi

DEST_PARENT="$(dirname "${DEST}")"
refuse_symlink() { if [ -L "$1" ]; then fail "$1 is a symbolic link — refusing (nothing of ours is one; something planted it)"; fi; }
# check_root_tree DIR — a real directory; no symlink anywhere inside; every entry root-owned; nothing
# group/other-writable. `find -P` never follows links, and the trailing slash makes find descend DIR.
check_root_tree() {
  local d="$1"
  [ -d "${d}" ] && [ ! -L "${d}" ] || fail "${d} is not a real directory"
  [ -z "$(find -P "${d}/" -type l -print -quit)" ] || fail "${d} contains a symbolic link"
  [ -z "$(find -P "${d}/" ! -user root -print -quit)" ] || fail "${d} has entries not owned by root"
  [ -z "$(find -P "${d}/" \( -perm -g+w -o -perm -o+w \) -print -quit)" ] || fail "${d} has group/other-writable entries"
}
# A bare rename(2): no copy fallback, no "move into the directory" when the target is one.
rename_root() { sudo /usr/bin/perl -e 'rename($ARGV[0], $ARGV[1]) or die "rename $ARGV[0] -> $ARGV[1]: $!\n"' "$1" "$2"; }

refuse_symlink "${DEST_PARENT}"
[ -d "${DEST_PARENT}" ] || fail "${DEST_PARENT} does not exist"
refuse_symlink "${DEST}"
if [ -e "${DEST}" ]; then
  existing_id="$(plist_get "${DEST}" CFBundleIdentifier)"
  [ "${existing_id}" = "${BUNDLE_ID}" ] \
    || fail "${DEST} exists and its bundle id is '${existing_id}', not ${BUNDLE_ID} — refusing to replace it"
fi
if pgrep -x Battery >/dev/null 2>&1; then
  fail "Battery is running. Quit it first (menu bar icon → right-click → Quit), then re-run."
fi
base_mode="$(stat -f '%Su %Sp' "${STAGE_BASE}")"
case "${base_mode}" in "root d"*t) ;; *) fail "${STAGE_BASE} is not a root-owned sticky directory (${base_mode})" ;; esac

say "sudo is needed to write a root-owned bundle into ${DEST_PARENT}"
sudo -v

STAGE_DIR=""; MOVED_PREV=0; PLACED_NEW=0; INSTALLED=0
on_exit() {
  local rc=$? keep=0
  set +e                                      # the rollback must run to the end whatever fails in it
  if [ "${INSTALLED}" -eq 0 ] && { [ "${MOVED_PREV}" -eq 1 ] || [ "${PLACED_NEW}" -eq 1 ]; }; then
    # Whatever sits at DEST now — the new bundle that failed its post-install verify, or something
    # planted in the gap between the two renames — goes into the root-only stage dir (and is deleted
    # with it). Then the previous install, if there was one, goes back.
    if [ -e "${DEST}" ] || [ -L "${DEST}" ]; then
      rename_root "${DEST}" "${STAGE_DIR}/failed.app" \
        || printf 'install-release: WARNING: could not move %s out of the way\n' "${DEST}" >&2
    fi
    if [ "${MOVED_PREV}" -eq 1 ] && [ -L "${STAGE_DIR}/previous/Battery.app" ]; then
      printf 'install-release: WARNING: what was at %s is a symbolic link (planted?) — not restoring it; %s is now empty\n' "${DEST}" "${DEST}" >&2
    elif [ "${MOVED_PREV}" -eq 1 ]; then
      if rename_root "${STAGE_DIR}/previous/Battery.app" "${DEST}"; then
        printf 'install-release: restored the previous %s\n' "${DEST}" >&2
      else
        keep=1
        printf 'install-release: WARNING: could not restore the previous install; it is kept at %s/previous/Battery.app\n' "${STAGE_DIR}" >&2
      fi
    fi
  fi
  if [ -n "${STAGE_DIR}" ] && [ "${keep}" -eq 0 ]; then sudo /bin/rm -rf "${STAGE_DIR}" 2>/dev/null; fi
  exit "${rc}"
}
trap on_exit EXIT

STAGE_DIR="$(sudo /usr/bin/mktemp -d "${STAGE_BASE}/battery-install.XXXXXXXX")" || fail "mktemp failed"
[ -d "${STAGE_DIR}" ] && [ ! -L "${STAGE_DIR}" ] || fail "stage dir ${STAGE_DIR} is not a real directory"
[ "$(stat -f '%Su' "${STAGE_DIR}")" = "root" ] || fail "stage dir ${STAGE_DIR} is not root-owned"
[ "$(stat -f '%d' "${STAGE_DIR}")" = "$(stat -f '%d' "${DEST_PARENT}")" ] \
  || fail "${STAGE_DIR} and ${DEST_PARENT} are on different volumes — the final rename would not be atomic"
sudo /bin/chmod 755 "${STAGE_DIR}"            # readable by you for the verify; writable only by root
STAGED="${STAGE_DIR}/Battery.app"

sudo /usr/bin/ditto "${APP}" "${STAGED}"
sudo /usr/sbin/chown -R -P root:wheel "${STAGED}"
sudo /bin/chmod -R -P go-w "${STAGED}"
check_root_tree "${STAGED}"
verify_bundle "${STAGED}"                     # the BINDING verify: on the copy nobody but root can change

refuse_symlink "${DEST}"
if [ -e "${DEST}" ]; then
  [ "$(plist_get "${DEST}" CFBundleIdentifier)" = "${BUNDLE_ID}" ] || fail "${DEST} changed since the pre-check — refusing"
  sudo /bin/mkdir "${STAGE_DIR}/previous"
  rename_root "${DEST}" "${STAGE_DIR}/previous/Battery.app" || fail "could not move the previous ${DEST} aside"
  MOVED_PREV=1
  # A link swapped in at DEST after the check above would have been renamed here as itself. The trap
  # will not restore a link, so failing here leaves DEST empty rather than pointing somewhere planted.
  refuse_symlink "${STAGE_DIR}/previous/Battery.app"
fi
rename_root "${STAGED}" "${DEST}" || fail "could not rename the new bundle into place"
PLACED_NEW=1
refuse_symlink "${DEST}"
check_root_tree "${DEST}"
verify_bundle "${DEST}"
owner="$(stat -f '%Su:%Sg' "${DEST}")"
[ "${owner}" = "root:wheel" ] || fail "${DEST} is owned by ${owner}, expected root:wheel"
INSTALLED=1                                   # only now may the EXIT trap drop the previous install
say "installed ${DEST} (root:wheel, no symlinks, no group/other write)."

cat <<EOF

install-release: NEXT STEPS (by hand — this script launches and registers nothing)
  1. Open ${DEST}. macOS asks once to approve the background item (System Settings → General →
     Login Items & Extensions). The app registers the helper from THIS bundle.
  2. Confirm launchd runs the helper from /Applications, not from build/:
       sudo launchctl print system/${HELPER_ID} | grep -iE 'program|path'
     If it still names build/sym, use Settings → Restart helper in the /Applications app (it
     unregisters and re-registers from the bundle it runs in), then re-check.
EOF
cat <<EOF
  3. From now on open ${DEST}, not the copy under build/, and quit any build/ copy that is running.
     Old Debug builds under build/ can be listed (and removed) with scripts/purge-old-builds.sh.
EOF
