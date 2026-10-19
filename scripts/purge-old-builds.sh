#!/usr/bin/env bash
#
# purge-old-builds.sh — find (and, only with --delete, remove) team-signed Battery.app build products
# that sit below the current trust floors.
# =============================================================================================
# WHY (security posture, 2026-10-15): the helper's floors (shared/DesignatedRequirement.swift) only
# help if no older app + helper pair survives. The helper-version floor is enforced by the APP's pin,
# not by launchd: an old 1.0 app still carries its own 0.1 helper and daemon plist, and a same-user
# process that attaches to that old (get-task-allow) app can make it register THAT helper as root —
# one that accepts a debuggable client. Every such bundle signed by this team is a live risk, and
# dozens pile up in build dirs, agent worktrees and DerivedData.
#
# SCOPE — build products only, never anything else:
#   <repo>/build/**                      the main checkout's build dirs (sym, sym-release, sym-*, dd*, ...)
#   <repo>/.claude/worktrees/*/build/**  agent worktrees' build dirs
#   ~/Library/Developer/Xcode/DerivedData/Battery-*/**   this project's DerivedData
# NEVER /Applications, never any other path: every root is resolved with realpath and must sit under
# the main checkout or DerivedData. <repo> is the MAIN checkout (git common dir), so this works the
# same when run from a worktree.
#
# A bundle is a CANDIDATE when its bundle id is com.example.batteryapp, it is signed by this team
# (Signing.xcconfig DEVELOPMENT_TEAM), and its app version is below minAppShortVersion, OR its
# embedded helper is below minHelperShortVersion, OR its signature no longer verifies. Versions are
# judged by `codesign --verify -R 'info[CFBundleShortVersionString] >= "…"'` — the same evaluator the
# pins use (numeric comparison).
#
# IN USE: a bundle any running process executes from is never deleted. Paths come from
# proc_pidpath(3) (a tiny C lister compiled into a temp dir), NOT `ps -o comm=`: measured
# 2026-10-15, ps shows launchd's root daemon as the RELATIVE "Contents/MacOS/com.example.batteryapp.
# energyhelper", while proc_pidpath resolves it, unprivileged, to the absolute path in its bundle.
# --delete is REFUSED outright if the lister is unavailable, or if any process whose name is ours
# (or unknown) cannot be resolved — deleting the bundle a live daemon runs from would surface only
# after a reboot, as "helper not responding".
#
# Usage:
#   scripts/purge-old-builds.sh            list only (the default; changes nothing)
#   scripts/purge-old-builds.sh --delete   remove every candidate that is not in use
#
# TEST MODE (scripts/purge-old-builds-selftest.sh only): PURGE_TEST_ROOT=<dir> scans just that dir and
# NEVER deletes (--delete prints what it would remove); PURGE_TEST_PROCESS_LIST=<file> replaces the live
# process list ("pid<TAB>path" or "pid<TAB>?<TAB>name" lines); PURGE_TEST_MIN_APP overrides the app floor;
# PURGE_TEST_EXTRA_PIDS="<pid> …" makes the live lister also judge those pids (e.g. one that has exited).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON="$(git -C "${CHECKOUT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "${COMMON}" ] && [ "$(basename "${COMMON}")" = ".git" ]; then MAIN="$(dirname "${COMMON}")"; else MAIN="${CHECKOUT}"; fi
DD="${HOME}/Library/Developer/Xcode/DerivedData"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BUNDLE_ID="com.example.batteryapp"
HELPER_ID="com.example.batteryapp.energyhelper"

DELETE=0
case "${1:-}" in
  "") ;;
  --delete) DELETE=1 ;;
  -h|--help) sed -n '2,43p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) printf 'purge-old-builds: unknown argument %s (see --help)\n' "$1" >&2; exit 2 ;;
esac

say()  { printf 'purge-old-builds: %s\n' "$*"; }
fail() { printf 'purge-old-builds: FAIL: %s\n' "$*" >&2; exit 1; }

TEST_ROOT="${PURGE_TEST_ROOT:-}"
TEST_MODE=0; [ -n "${TEST_ROOT}" ] && TEST_MODE=1

src_const() { sed -n "s/.*static let $1 = \"\\(.*\\)\".*/\\1/p" "${CHECKOUT}/shared/DesignatedRequirement.swift" | head -1; }
MIN_APP="$(src_const minAppShortVersion)"
MIN_HELPER="$(src_const minHelperShortVersion)"
TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' "${CHECKOUT}/Signing.xcconfig" | head -1)"
[ -n "${MIN_APP}" ] && [ -n "${MIN_HELPER}" ] && [ -n "${TEAM}" ] || fail "could not read the floors / Team ID from this checkout"
if [ "${TEST_MODE}" -eq 1 ] && [ -n "${PURGE_TEST_MIN_APP:-}" ]; then MIN_APP="${PURGE_TEST_MIN_APP}"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/purge-old-builds.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# ---- the scan roots, each resolved and confined ------------------------------------------------
MAIN_REAL="$(realpath "${MAIN}")"
DD_REAL="$( [ -d "${DD}" ] && realpath "${DD}" || printf '%s' "${DD}")"
allowed_root() {   # realpath'd root must sit under the main checkout or DerivedData (or the test root)
  if [ "${TEST_MODE}" -eq 1 ]; then [ "$1" = "$(realpath "${TEST_ROOT}")" ]; return; fi
  case "$1" in "${MAIN_REAL}/"*|"${DD_REAL}/"*) return 0 ;; *) return 1 ;; esac
}
CANDIDATE_ROOTS=()
if [ "${TEST_MODE}" -eq 1 ]; then
  [ -d "${TEST_ROOT}" ] || fail "PURGE_TEST_ROOT ${TEST_ROOT} is not a directory"
  CANDIDATE_ROOTS+=("${TEST_ROOT}")
else
  [ -d "${MAIN}/build" ] && CANDIDATE_ROOTS+=("${MAIN}/build")
  for w in "${MAIN}/.claude/worktrees/"*/build; do [ -d "${w}" ] && CANDIDATE_ROOTS+=("${w}"); done
  for d in "${DD}/Battery-"*; do [ -d "${d}" ] && CANDIDATE_ROOTS+=("${d}"); done
fi
ROOTS=()
for r in ${CANDIDATE_ROOTS[@]+"${CANDIDATE_ROOTS[@]}"}; do
  rr="$(realpath "${r}")"
  if allowed_root "${rr}"; then ROOTS+=("${rr}"); else say "SKIP root (resolves outside the allowed locations): ${r} -> ${rr}"; fi
done

# The only places a deletion may ever happen (paths are under realpath'd roots).
in_scope() {
  [ "${TEST_MODE}" -eq 0 ] || return 1
  case "$1" in
    "${MAIN_REAL}/build/"*/Battery.app) return 0 ;;
    "${MAIN_REAL}/.claude/worktrees/"*/build/*/Battery.app) return 0 ;;
    "${DD_REAL}/Battery-"*/Battery.app) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- every running process's real executable path ---------------------------------------------
# RUNNING holds "\n<pid>\t<path>" per process (a leading newline so every entry starts "\n<pid>\t").
# Matching is done in the shell, never `printf | grep -q` (under pipefail an early-exiting grep can
# report a match as a failure, and a pipe only holds so much).
PROC_OK=1; UNRESOLVED_OURS=""
cat > "${WORK}/pidpaths.c" <<'EOF'
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
// Prints "<pid>\t<path>" per process, or "<pid>\t?\t<name|?>" when the path cannot be read. A pid
// whose path AND name both fail and that kill(pid, 0) reports gone (ESRCH) exited mid-scan: it is
// skipped, so a process ending during the scan never blocks --delete. Extra pids given as arguments
// (test mode only) are appended to the list.
static void report(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE], name[2 * MAXCOMLEN + 1];
    if (pid <= 0) return;
    if (proc_pidpath(pid, path, sizeof path) > 0) { printf("%d\t%s\n", pid, path); return; }
    if (proc_name(pid, name, sizeof name) > 0) { printf("%d\t?\t%s\n", pid, name); return; }
    if (kill(pid, 0) == -1 && errno == ESRCH) return;   // exited since proc_listallpids
    printf("%d\t?\t?\n", pid);
}
int main(int argc, char **argv) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 2;
    int cap = n + 512;
    pid_t *pids = calloc((size_t)cap, sizeof(pid_t));
    if (!pids) return 2;
    n = proc_listallpids(pids, cap * (int)sizeof(pid_t));
    if (n <= 0) return 2;
    for (int i = 0; i < n; i++) report(pids[i]);
    for (int i = 1; i < argc; i++) report((pid_t)atoi(argv[i]));
    return 0;
}
EOF
EXTRA_PIDS=()
if [ "${TEST_MODE}" -eq 1 ] && [ -n "${PURGE_TEST_EXTRA_PIDS:-}" ]; then read -r -a EXTRA_PIDS <<< "${PURGE_TEST_EXTRA_PIDS}"; fi
if [ "${TEST_MODE}" -eq 1 ] && [ -n "${PURGE_TEST_PROCESS_LIST:-}" ]; then
  PROCS="$(cat "${PURGE_TEST_PROCESS_LIST}")"
elif xcrun clang -O2 -o "${WORK}/pidpaths" "${WORK}/pidpaths.c" >/dev/null 2>&1 \
     && PROCS="$("${WORK}/pidpaths" ${EXTRA_PIDS[@]+"${EXTRA_PIDS[@]}"})"; then
  :
else
  PROC_OK=0; PROCS=""
  say "WARNING: could not list processes with proc_pidpath (clang unavailable?) — IN-USE cannot be judged; --delete is disabled"
fi
RUNNING=$'\n'
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  pid="${line%%$'\t'*}"; rest="${line#*$'\t'}"
  if [[ "${rest}" == "?"$'\t'* ]]; then
    name="${rest#?$'\t'}"
    # An unresolvable process that is (or may be) ours: the helper, the app, or a name we cannot read.
    case "${name}" in com.example.batteryapp*|Battery|"?") UNRESOLVED_OURS="${UNRESOLVED_OURS} ${pid}(${name})" ;; esac
  else
    RUNNING+="${pid}"$'\t'"${rest}"$'\n'
  fi
done <<< "${PROCS}"
in_use() { [[ "${RUNNING}" == *$'\t'"$1/"* ]]; }

# ---- scan ----------------------------------------------------------------------------------------
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
team_of()   { local i; i="$(codesign -dv "$1" 2>&1 || true)"; [[ "${i}" =~ TeamIdentifier=([A-Z0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"; true; }
meets()     { codesign --verify -R="info[CFBundleShortVersionString] >= \"$2\"" "$1" >/dev/null 2>&1; }
helper_version() { # display only; the helper's Info.plist is an XML section embedded in the Mach-O
  local s; s="$(strings -a "$1" 2>/dev/null || true)"
  s="${s#*<key>CFBundleShortVersionString</key>}"; s="${s#*<string>}"; s="${s%%</string>*}"
  [ -n "${s}" ] && [ "${#s}" -lt 20 ] && printf '%s' "${s}" || printf '?'
}

[ "${TEST_MODE}" -eq 0 ] || say "TEST MODE: scanning ${TEST_ROOT} only; nothing will be deleted"
say "floors: app >= ${MIN_APP}, helper >= ${MIN_HELPER}; team ${TEAM}; main checkout ${MAIN}"
say "scanning ${#ROOTS[@]} build root(s) (never /Applications)"
printf '%-10s %-6s %-6s %s\n' STATUS APP HELPER PATH

CANDIDATES=(); n_ok=0; n_other=0; n_inuse=0
for root in ${ROOTS[@]+"${ROOTS[@]}"}; do
  while IFS= read -r -d '' app; do
    [ -L "${app}" ] && continue
    [ "$(plist_get "${app}/Contents/Info.plist" CFBundleIdentifier)" = "${BUNDLE_ID}" ] || continue
    if [ "$(team_of "${app}")" != "${TEAM}" ]; then n_other=$((n_other + 1)); continue; fi
    av="$(plist_get "${app}/Contents/Info.plist" CFBundleShortVersionString)"
    helper="${app}/Contents/MacOS/${HELPER_ID}"
    hv="-"; [ -f "${helper}" ] && hv="$(helper_version "${helper}")"
    reason=""
    if ! codesign --verify "${app}" >/dev/null 2>&1; then reason="BADSIG"
    elif ! meets "${app}" "${MIN_APP}"; then reason="OLD-APP"
    elif [ -f "${helper}" ] && ! meets "${helper}" "${MIN_HELPER}"; then reason="OLD-HELPER"
    fi
    if [ -z "${reason}" ]; then n_ok=$((n_ok + 1)); printf '%-10s %-6s %-6s %s\n' current "${av}" "${hv}" "${app}"; continue; fi
    if in_use "${app}"; then
      n_inuse=$((n_inuse + 1)); printf '%-10s %-6s %-6s %s\n' "IN-USE" "${av}" "${hv}" "${app}  (${reason}; a running process executes from it — quit/relaunch, then re-run)"
      continue
    fi
    printf '%-10s %-6s %-6s %s\n' "${reason}" "${av}" "${hv}" "${app}"
    CANDIDATES+=("${app}")
  done < <(find -P "${root}" -type d -name Battery.app -prune -print0 2>/dev/null)
done

say "${#CANDIDATES[@]} below the floor and removable, ${n_inuse} below the floor but in use, ${n_ok} current, ${n_other} not signed by team ${TEAM} (ignored)"
[ -z "${UNRESOLVED_OURS}" ] || say "WARNING: process(es) that may be ours could not be resolved:${UNRESOLVED_OURS} — --delete is disabled"

if [ "${DELETE}" -eq 0 ]; then
  [ "${#CANDIDATES[@]}" -eq 0 ] || say "nothing was deleted. To remove the ${#CANDIDATES[@]} listed above: scripts/purge-old-builds.sh --delete"
  exit 0
fi

[ "${PROC_OK}" -eq 1 ] || fail "refusing --delete: running processes could not be listed, so IN-USE is unknown"
[ -z "${UNRESOLVED_OURS}" ] || fail "refusing --delete: could not resolve the executable of${UNRESOLVED_OURS}; a live daemon may run from one of these bundles"

removed=0
for app in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
  if [ "${TEST_MODE}" -eq 1 ]; then say "TEST MODE: would remove ${app}"; continue; fi
  if ! in_scope "${app}" || [ -L "${app}" ]; then say "SKIP (out of scope or a symlink): ${app}"; continue; fi
  if in_use "${app}"; then say "SKIP (now in use): ${app}"; continue; fi
  if rm -rf -- "${app}"; then removed=$((removed + 1)); say "removed ${app}"; else say "could not remove ${app}"; fi
done
[ "${TEST_MODE}" -eq 1 ] || say "removed ${removed} of ${#CANDIDATES[@]}."
