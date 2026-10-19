#!/usr/bin/env bash
#
# ui-orphan-diff-gate.sh — the #29 C1 guard's higher-signal half: catch the orphan AT AUTHORING TIME.
# =============================================================================================
# WHY THIS EXISTS
#   `scripts/ui-orphan-gate.sh` sweeps a TREE. It answers "is anything dark right now?" — which is a
#   real question, but it answers it weeks late and, once an orphan is parked on the allowlist, it
#   stops answering it at all. The audit (§2.C, §5.2 row 15) names the complementary check as the
#   valuable one:
#
#     "a `git diff` rule requiring any commit that removes a symbol's last reference to either delete
#      the symbol or name it in a `Re-homed:` manifest. That is the check that would have caught
#      `f2f1eaa` at authoring time."
#
#   This is that rule. The failure it exists to prevent is not "a symbol is dark" but "a symbol went
#   dark in THIS commit and nobody noticed", which is exactly how ~23 user-visible symbols were lost
#   across `44cfb79` -> `f2f1eaa` with the whole suite green.
#
# THE RULE, precisely
#   For each commit in the range, compare the app/ tree BEFORE and AFTER:
#     a declaration that was LIVE before (had a reader in another app/ file) and is ORPHANED after
#     (has none) must be accounted for. The commit passes only if it either
#       (1) deleted the declaration too  — then it is not in the "after" inventory at all, or
#       (2) named the symbol in a `Re-homed:` manifest line in the commit message, or
#       (3) the symbol is on the shared ui-orphan-allowlist.txt (the heuristic's known false positives
#           live there already; a second amnesty list would rot twice as fast).
#
# MANIFEST SYNTAX — one symbol per line, in the commit message body:
#
#     Re-homed: <Symbol> -> <where it is read now, or why it is deliberately dark>
#
#   The `-> destination` half is REQUIRED and is the whole point. A bare symbol name would be a rubber
#   stamp — you could clear a real orphan by typing its name. Being made to write "-> rendered by
#   d6HealthCard" or "-> parked for D-6, no screen yet, owner ruling pending" is the moment the author
#   discovers which of those two sentences is true. Same discipline as the allowlist's required
#   `# reason`. Multiple `Re-homed:` lines are allowed; case-insensitive on the keyword.
#
#   Examples:
#     Re-homed: chargeLimitSection -> replaced by SettingsView charge-control group (D-4b)
#     Re-homed: keepAwakeSection -> NO HOME YET, needs a re-home-or-drop ruling (tripwire held)
#
# ONE DEFINITION OF "UI-FACING"
#   This script does NOT re-implement the heuristic. It drives `ui-orphan-gate.sh --inventory` over
#   each tree and diffs the verdicts. Two subtly disagreeing definitions of "UI-facing" would be worse
#   than one, and the sibling gate already carries a fix (`cdceb58`) for a name-extraction defect that
#   a re-implementation would have been free to reintroduce. Whatever that gate learns, this inherits.
#
# COVERAGE — READ THIS BEFORE TRUSTING IT
#   Inherited blind spots (all of them, unchanged): short/common names are UNSWEPT and this gate is
#   equally blind to them, so a commit that orphans `soc` or `note` passes clean; `private` /
#   `fileprivate` declarations are skipped; only app/ is examined; only the name-suffix / @Published /
#   *Strings.swift shapes count as UI-facing.
#
#   Blind spots that are this gate's OWN:
#     * SAME-FILE readers. The inventory's reader test ignores same-file uses by design. A symbol read
#       only from within its own file reads as ORPHAN in both trees, so it can never "go dark" here.
#     * ALREADY DARK stays dark. A symbol orphaned by an EARLIER commit is invisible to every later
#       one. This gate catches the transition, never the state — run the tree gate for the state.
#     * SPLIT COMMITS. Delete the call site in commit A, delete the symbol in commit B, and A fires
#       (correctly — at A the symbol IS dark). Run the range, not one commit, and read the whole range
#       verdict; a symbol that A orphans and B deletes still costs you a `Re-homed:` line at A. That is
#       a deliberate cost, not an oversight: `44cfb79` was exactly commit A.
#     * BORN DARK is reported but does NOT fail. A declaration ADDED with no reader is the same bug
#       class, but a micro-commit-per-stage workflow produces them legitimately (declare the string in
#       one stage, render it in the next). Advisory only — see the ADVISORY block in the output.
#     * MERGE COMMITS are skipped. A three-way inventory diff is not a thing this can honestly do.
#     * RENAMES read as delete + born-dark, not as a rename.
#
# Usage:
#   ui-orphan-diff-gate.sh [--list] [--repo DIR] [--allowlist FILE] [RANGE]
#     --list       report and exit 0 regardless (triage mode, never enforcement)
#     --repo DIR   repository to examine (default: this script's repo). The heuristic itself always
#                  comes from THIS checkout's ui-orphan-gate.sh — that is what keeps it single-sourced.
#     --allowlist  amnesty file (default: scripts/ui-orphan-allowlist.txt, shared with the tree gate)
#     RANGE        a git range (`a..b`) or a single commit (`f2f1eaa`, meaning that commit vs its parent).
#             Default: HEAD~1..HEAD — the commit you just wrote, which is the point of the exercise.
#
# Exit 0 = every commit in the range either kept its symbols read, deleted them, or declared them.

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TREE_GATE="${SCRIPT_DIR}/ui-orphan-gate.sh"
ALLOWLIST="${SCRIPT_DIR}/ui-orphan-allowlist.txt"

LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --list)      LIST_ONLY=1; shift ;;
    --repo)      REPO_ROOT="$(cd "${2:?--repo needs a directory}" && pwd)"; shift 2 ;;
    --allowlist) ALLOWLIST="${2:?--allowlist needs a file}"; shift 2 ;;
    *)           break ;;
  esac
done
RANGE="${1:-HEAD~1..HEAD}"

if [ ! -x "${TREE_GATE}" ] && [ ! -f "${TREE_GATE}" ]; then
  echo "ui-orphan-diff-gate: sibling gate not found: ${TREE_GATE}" >&2
  exit 2
fi
if ! git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ui-orphan-diff-gate: not a git repository: ${REPO_ROOT}" >&2
  exit 2
fi

if [ -t 1 ]; then BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
else BOLD=""; RED=""; GRN=""; YEL=""; RST=""; fi

# A single commit is shorthand for "that commit against its parent".
case "${RANGE}" in
  *..*) REVS="$(git -C "${REPO_ROOT}" rev-list --no-merges --reverse "${RANGE}" 2>/dev/null)" ;;
  *)    REVS="$(git -C "${REPO_ROOT}" rev-list --no-merges -1 "${RANGE}" 2>/dev/null)" ;;
esac
if [ -z "${REVS}" ]; then
  echo "ui-orphan-diff-gate: range resolved to no (non-merge) commits: ${RANGE}" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ui-orphan-diff.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# ---------------------------------------------------------------------------- inventory, cached
# Cached on the app/ TREE object, not the commit: a docs-only commit shares its parent's app tree and
# costs nothing, and consecutive commits share one tree each. Over a 30-commit range that is the
# difference between ~60 gate runs and ~31.
app_tree_sha() {
  git -C "${REPO_ROOT}" rev-parse "$1:app" 2>/dev/null || echo "MISSING"
}

# inventory_for <tree-sha> <rev> -> path to a `STATUS<TAB>name<TAB>file` file
inventory_for() {
  local tree="$1" rev="$2" out="${WORK}/inv-$1.tsv" src="${WORK}/src-$1"
  [ -f "${out}" ] && { printf '%s' "${out}"; return 0; }
  if [ "${tree}" = "MISSING" ]; then : > "${out}"; printf '%s' "${out}"; return 0; fi
  mkdir -p "${src}"
  git -C "${REPO_ROOT}" archive "${rev}" app 2>/dev/null | tar -x -C "${src}" 2>/dev/null
  if [ -d "${src}/app" ]; then
    bash "${TREE_GATE}" --inventory "${src}/app" /dev/null > "${out}" 2>/dev/null
  else
    : > "${out}"
  fi
  rm -rf "${src}"
  printf '%s' "${out}"
}

status_of() { awk -F'\t' -v n="$2" '$2 == n { print $1; exit }' "$1"; }

# ---------------------------------------------------------------------------- manifest
# `Re-homed: <Symbol> -> <destination>`. The `->` is required; a bare name does not clear anything.
manifest_names() {
  git -C "${REPO_ROOT}" log -1 --format='%B' "$1" \
    | sed -nE 's/^[[:space:]]*[Rr]e-homed:[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*->[[:space:]]*[^[:space:]].*$/\1/p'
}

allowlisted() {
  [ -f "${ALLOWLIST}" ] || return 1
  grep -qE "^[[:space:]]*$1[[:space:]]*(#.*)?$" "${ALLOWLIST}"
}

# ---------------------------------------------------------------------------- run
echo "=== UI-ORPHAN DIFF gate (#29 C1 — authoring-time half) ==========================="
echo "  repo      : ${REPO_ROOT}"
echo "  range     : ${RANGE}"
echo "  commits   : $(printf '%s\n' "${REVS}" | wc -l | tr -d ' ') (merges skipped)"
echo "  definition: ${TREE_GATE} --inventory (one heuristic, shared)"
echo "----------------------------------------------------------------------------------"

FAIL=0
WENT_DARK_TOTAL=0
CLEARED_TOTAL=0
BORN_DARK_TOTAL=0
EXAMINED=0

for rev in ${REVS}; do
  parent="$(git -C "${REPO_ROOT}" rev-parse -q --verify "${rev}^" 2>/dev/null)" || parent=""
  [ -n "${parent}" ] || continue

  ptree="$(app_tree_sha "${parent}")"
  ctree="$(app_tree_sha "${rev}")"
  [ "${ptree}" = "${ctree}" ] && continue     # app/ untouched — nothing this gate can say
  EXAMINED=$((EXAMINED + 1))

  pinv="$(inventory_for "${ptree}" "${parent}")"
  cinv="$(inventory_for "${ctree}" "${rev}")"

  MANIFEST="$(manifest_names "${rev}")"
  subject="$(git -C "${REPO_ROOT}" log -1 --format='%s' "${rev}")"
  short="$(git -C "${REPO_ROOT}" rev-parse --short "${rev}")"

  went=""; born=""
  while IFS=$'\t' read -r st name file; do
    [ "${st}" = "ORPHAN" ] || continue
    pst="$(status_of "${pinv}" "${name}")"
    case "${pst}" in
      LIVE) went="${went}${name}|${file}"$'\n' ;;
      "")   born="${born}${name}|${file}"$'\n' ;;
      *)    : ;;                               # ORPHAN or UNSWEPT before — not a transition
    esac
  done < "${cinv}"

  [ -z "${went}" ] && [ -z "${born}" ] && continue

  echo "  ${BOLD}${short}${RST}  ${subject}"

  if [ -n "${went}" ]; then
    while IFS='|' read -r name file; do
      [ -n "${name}" ] || continue
      WENT_DARK_TOTAL=$((WENT_DARK_TOTAL + 1))
      why=""
      case " $(printf '%s ' ${MANIFEST}) " in *" ${name} "*) why="declared Re-homed:" ;; esac
      [ -z "${why}" ] && allowlisted "${name}" && why="on ui-orphan-allowlist.txt"
      if [ -n "${why}" ]; then
        CLEARED_TOTAL=$((CLEARED_TOTAL + 1))
        printf '      %-34s %sLAST READER REMOVED%s — %s\n' "${name}" "${YEL}" "${RST}" "${why}"
      else
        FAIL=1
        printf '      %-34s %sLAST READER REMOVED, UNDECLARED%s  (%s)\n' \
          "${name}" "${RED}" "${RST}" "$(basename "${file}")"
      fi
    done <<< "${went}"
  fi

  if [ -n "${born}" ]; then
    while IFS='|' read -r name file; do
      [ -n "${name}" ] || continue
      BORN_DARK_TOTAL=$((BORN_DARK_TOTAL + 1))
      printf '      %-34s %sborn dark (advisory, not a failure)%s  (%s)\n' \
        "${name}" "${YEL}" "${RST}" "$(basename "${file}")"
    done <<< "${born}"
  fi
done

echo "----------------------------------------------------------------------------------"
echo "  commits touching app/ : ${EXAMINED}"
echo "  went dark             : ${WENT_DARK_TOTAL} (${CLEARED_TOTAL} declared or allowlisted)"
echo "  born dark (advisory)  : ${BORN_DARK_TOTAL}"

# COVERAGE disclosure — never a failure, always printed. Same contract as the tree gate: a check that
# does not say what it cannot see manufactures confidence it has not earned.
echo "----------------------------------------------------------------------------------"
echo "  ${BOLD}COVERAGE${RST} — what this did NOT check:"
echo "    * short/common names (soc, note, state, ...) are UNSWEPT upstream and equally invisible here"
echo "    * a symbol read ONLY from its own file reads as orphaned in both trees and can never fire"
echo "    * a symbol already dark before this range stays invisible — this catches TRANSITIONS only"
echo "    * merge commits skipped; renames read as delete + born-dark"
echo "    * born-dark declarations are reported, never enforced (micro-commits create them legitimately)"

echo "=================================================================================="
if [ "${FAIL}" -eq 0 ]; then
  echo "UI-ORPHAN DIFF GATE: ${GRN}PASSED${RST} — no commit left a symbol dark without saying so."
else
  echo "UI-ORPHAN DIFF GATE: ${RED}FAILED${RST} — a commit removed a symbol's last reader and neither"
  echo "  deleted the symbol nor declared it. Fix by one of:"
  echo "    * give it a reader (re-home it — this is usually the bug)"
  echo "    * delete it in the same commit"
  echo "    * add to the commit message:  Re-homed: <Symbol> -> <where it is read now, or why it is dark>"
fi
[ "${LIST_ONLY}" = "1" ] && exit 0
exit "${FAIL}"
