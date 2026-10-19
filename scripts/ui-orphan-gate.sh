#!/usr/bin/env bash
#
# ui-orphan-gate.sh — the #29 C1 regression gate ("a shipped feature must have a screen").
# =============================================================================================
# WHY THIS EXISTS
#   `44cfb79` deleted the transitional Details tail that was CALLING ~16 relocated popover builders.
#   `f2f1eaa` then correctly observed those builders were unreferenced and excised them — but they were
#   unreferenced because their only call site had just been deleted, not because the features were
#   retired. ~23 user-visible symbols went dark with the whole suite still green, including nine tenths
#   of the charge-control honesty layer. Swift gives nothing free here: the compiler does NOT warn on an
#   unused `internal` declaration, and a unit test that asserts a string is PRODUCED passes happily while
#   nothing RENDERS it.
#
#   This gate is the missing signal: a UI-facing declaration that no other production file reads.
#
# WHAT IT CHECKS
#   (a) ORPHANS — every UI-facing declaration under app/ has at least one production reader in a
#       DIFFERENT app/ file. Tests do not count: a test is exactly what kept these symbols looking alive.
#   (b) ALLOWLIST FRESHNESS — every entry in the allowlist is STILL an orphan. An entry that has since
#       gained a reader FAILS the gate, so the allowlist cannot rot into permanent amnesty.
#
# WHAT COUNTS AS "UI-FACING" (heuristic, deliberately narrow — see COVERAGE below)
#   1. `@Published` properties. These exist to drive a view; one nothing reads is the bug by definition.
#   2. `static func` / `static let` / `static var` in a `*Strings.swift` file — the user-string registers.
#   3. Any declaration whose NAME ends in a user-facing suffix: Text, Label, Tag, Note, Caveat,
#      Guidance, Prefix, Suggestion, Message, Summary.
#   `private` / `fileprivate` declarations are skipped (they CAN only be read in their own file, so
#   every one of them would be a false positive). `private(set)` is NOT private for reads and is swept.
#
# COVERAGE — READ THIS BEFORE TRUSTING IT
#   The honest weakness of this gate is FALSE NEGATIVES, not false positives. A bare word-boundary sweep
#   cannot distinguish `topUp.soc` from any other `soc` in the tree, so short and common identifiers are
#   NOT swept at all — `TopUpController.soc` and `.note`, both real #29 casualties, are exactly this
#   case. The gate does not pretend otherwise: it PRINTS every declaration it declined to sweep, by
#   name, under UNSWEPT. Those need qualified matching or a human. A gate that quietly skips them is
#   worse than no gate, because it manufactures confidence.
#
#   The complementary check — higher-signal, not implemented here — is a `git diff` rule: any commit
#   that removes a symbol's LAST reference must either delete the symbol or name it in a `Re-homed:`
#   manifest. That is the check that would have caught `f2f1eaa` at authoring time, before the symbol
#   spent a release dark.
#
#   That complementary check now EXISTS: `scripts/ui-orphan-diff-gate.sh`. It does not re-define
#   "UI-facing" — it drives THIS script in `--inventory` mode over two trees and diffs the verdicts,
#   so there is exactly one definition and it cannot drift. See that file for its own coverage note.
#
# Usage:
#   ui-orphan-gate.sh [--list|--inventory] [APP_DIR] [ALLOWLIST]
#     --list       print the orphan/unswept inventory and exit 0 regardless (triage, never enforcement)
#     --inventory  machine-readable: one `STATUS<TAB>name<TAB>file` line per declaration, exit 0.
#                  STATUS is LIVE (has an external reader), ORPHAN (does not), or UNSWEPT (name too
#                  short/common to sweep — NOT a verdict). The allowlist is NOT consulted: this mode
#                  reports what the heuristic SAW, and amnesty is the caller's business. Consumed by
#                  ui-orphan-diff-gate.sh; keep the format stable.
#   Defaults: APP_DIR=<repo>/app  ALLOWLIST=<repo>/scripts/ui-orphan-allowlist.txt
#
# Exit 0 = no un-allowlisted orphans and no stale allowlist entries.

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LIST_ONLY=0
INVENTORY_ONLY=0
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --list)      LIST_ONLY=1; shift ;;
    --inventory) INVENTORY_ONLY=1; shift ;;
    *)           break ;;
  esac
done

APP_DIR="${1:-${REPO_ROOT}/app}"
ALLOWLIST="${2:-${SCRIPT_DIR}/ui-orphan-allowlist.txt}"

if [ ! -d "${APP_DIR}" ]; then
  echo "ui-orphan-gate: app directory not found: ${APP_DIR}" >&2
  exit 2
fi

if [ -t 1 ]; then BOLD=$'\033[1m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
else BOLD=""; RED=""; GRN=""; YEL=""; RST=""; fi

# Identifiers too short or too common for a bare word-boundary sweep to mean anything. Declared here so
# the exclusion is a reviewable list, not an accident of the regex.
TOO_COMMON=" soc note id name state status limit value text label title body kind mode source series apps total watts phase reason detail message summary "
MIN_LEN=5

# ---------------------------------------------------------------------------- collect declarations
# Emits: <name>\t<declaring-file>, deduplicated, sorted.
#
# ONE grep pre-filters the handful of candidate LINES out of the whole tree, then one awk classifies
# them. (The obvious shape — a bash loop with a sed per source line — spawns ~90k processes and takes
# minutes; this takes under a second. Worth saying, because a gate nobody waits for is a gate nobody
# runs.)
DECL_RE='(@Published[[:space:]])|(^[[:space:]]*static[[:space:]]+(func|let|var)[[:space:]])|(^[[:space:]]*((static[[:space:]]+(func|var|let))|func|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*(Text|Label|Tag|Note|Caveat|Guidance|Prefix|Suggestion|Message|Summary)[^A-Za-z0-9_])'

collect_declarations() {
  grep -rHE --include='*.swift' -- "${DECL_RE}" "${APP_DIR}" 2>/dev/null | awk -F: '
    {
      file = $1
      line = $0
      sub(/^[^:]*:/, "", line)

      # `private(set)` is not private for READS — normalise it away before the private test.
      gsub(/private\(set\)/, "", line)
      if (line ~ /(^|[[:space:]])(private|fileprivate)[[:space:]]/) next

      name = ""
      # 1. @Published properties — they exist to drive a view.
      if (line ~ /@Published/) {
        if (match(line, /[[:space:]]var[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
          name = substr(line, RSTART, RLENGTH)
          sub(/^[[:space:]]*var[[:space:]]+/, "", name)
        }
      }
      # 2. statics in a *Strings.swift user-string register.
      if (name == "" && file ~ /Strings\.swift$/) {
        if (match(line, /^[[:space:]]*static[[:space:]]+(func|let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
          name = substr(line, RSTART, RLENGTH)
          sub(/^[[:space:]]*static[[:space:]]+(func|let|var)[[:space:]]+/, "", name)
        }
      }
      # 3. a user-facing suffix in the NAME itself.
      if (name == "") {
        # A bare `let` here matches LOCAL constants inside function bodies, which are not a surface at
        # all — require `static` for `let`. `var` / `func` stay unqualified: those are type members.
        # The trailing [^A-Za-z0-9_] is LOAD-BEARING and was missing here, though DECL_RE above
        # always had it. Without it the match stops at the suffix, so RLENGTH truncates the
        # identifier to its own prefix: inlineNoteSuppressed extracted as inlineNote, and the
        # reader test then searched for a name that does not exist and reported a LIVE symbol
        # with a real cross-file reader as an orphan. Any name that merely CONTAINS a suffix
        # keyword before more characters hit this. Found 2026-09-08 wiring B2.
        if (match(line, /^[[:space:]]*((static[[:space:]]+(func|var|let))|func|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*(Text|Label|Tag|Note|Caveat|Guidance|Prefix|Suggestion|Message|Summary)[^A-Za-z0-9_]/)) {
          name = substr(line, RSTART, RLENGTH - 1)
          sub(/^[[:space:]]*(static[[:space:]]+)?(func|var|let)[[:space:]]+/, "", name)
        }
      }
      if (name != "") print name "\t" file
    }' | sort -u
}

# ---------------------------------------------------------------------------- reader test
# A reader is a word-boundary occurrence of the identifier in an app/ .swift file OTHER than the one
# that declares it. Same-file uses do NOT count: `ChargeStatusStrings.errorLabel` was called only by
# `commandLabel` in its own file, and both were dark together — that is the transitive case this catches.
has_external_reader() {
  local name="$1" decl_file="$2" hit
  while IFS= read -r hit; do
    [ "${hit}" = "${decl_file}" ] && continue
    return 0
  done < <(grep -rlw --include='*.swift' -- "${name}" "${APP_DIR}" 2>/dev/null)
  return 1
}

is_too_common() {
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [ "${#1}" -lt "${MIN_LEN}" ] && return 0
  case "${TOO_COMMON}" in *" ${lower} "*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------- allowlist
# Format: one `Symbol` per line, `#` comments and blank lines ignored. Trailing `# reason` required by
# convention (not enforced) so an entry always carries its justification.
allowlisted() {
  [ -f "${ALLOWLIST}" ] || return 1
  grep -qE "^[[:space:]]*$1[[:space:]]*(#.*)?$" "${ALLOWLIST}"
}

allowlist_entries() {
  [ -f "${ALLOWLIST}" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "${ALLOWLIST}" | grep -v '^$' || true
}

# ---------------------------------------------------------------------------- run
if [ "${INVENTORY_ONLY}" = "0" ]; then
  echo "=== UI-ORPHAN gate (#29 C1) ======================================================"
  echo "  app dir   : ${APP_DIR}"
  echo "  allowlist : ${ALLOWLIST}"
  echo "----------------------------------------------------------------------------------"
fi

ORPHANS=""
UNSWEPT=""
INVENTORY=""
SEEN=""

while IFS=$'\t' read -r name file; do
  case " ${SEEN} " in *" ${name} "*) continue ;; esac
  SEEN="${SEEN} ${name}"
  if is_too_common "${name}"; then
    UNSWEPT="${UNSWEPT}${name}|${file}"$'\n'
    INVENTORY="${INVENTORY}UNSWEPT	${name}	${file}"$'\n'
    continue
  fi
  if ! has_external_reader "${name}" "${file}"; then
    ORPHANS="${ORPHANS}${name}|${file}"$'\n'
    INVENTORY="${INVENTORY}ORPHAN	${name}	${file}"$'\n'
  else
    INVENTORY="${INVENTORY}LIVE	${name}	${file}"$'\n'
  fi
done < <(collect_declarations)

# --inventory: emit the raw per-declaration verdict and stop. No allowlist, no pass/fail — this mode
# exists so a SECOND checker can reuse this one definition of "UI-facing" instead of inventing its own.
if [ "${INVENTORY_ONLY}" = "1" ]; then
  printf '%s' "${INVENTORY}"
  exit 0
fi

# (a) orphans
FAIL=0
UNALLOWED=0
if [ -n "${ORPHANS}" ]; then
  echo "  ${BOLD}orphaned UI-facing declarations (no reader in any other app/ file)${RST}"
  while IFS='|' read -r name file; do
    [ -n "${name}" ] || continue
    rel="${file#${REPO_ROOT}/}"
    if allowlisted "${name}"; then
      printf '    %-34s %-52s %sallowlisted%s\n' "${name}" "${rel}" "${YEL}" "${RST}"
    else
      printf '    %-34s %-52s %sORPHAN%s\n' "${name}" "${rel}" "${RED}" "${RST}"
      UNALLOWED=$((UNALLOWED + 1))
    fi
  done <<< "${ORPHANS}"
else
  echo "  ${GRN}no orphaned UI-facing declarations${RST}"
fi
[ "${UNALLOWED}" -gt 0 ] && FAIL=1

# (b) allowlist freshness — an entry that is no longer an orphan must be REMOVED, or the allowlist rots
# into permanent amnesty and the gate quietly stops meaning anything.
STALE=0
echo "----------------------------------------------------------------------------------"
while IFS= read -r entry; do
  [ -n "${entry}" ] || continue
  case "${ORPHANS}" in
    *"${entry}|"*) : ;;
    *)
      printf '    %-34s %sSTALE — it has a reader now; delete this allowlist line%s\n' "${entry}" "${RED}" "${RST}"
      STALE=$((STALE + 1))
      ;;
  esac
done < <(allowlist_entries)
if [ "${STALE}" -eq 0 ]; then
  echo "  ${GRN}allowlist is fresh (every entry is still a real orphan)${RST}"
fi
[ "${STALE}" -gt 0 ] && FAIL=1

# BACKLOG — allowlist entries the gate got RIGHT. These are dark features, parked so the gate can be
# enforcing against NEW orphans from day one; they are debt, not absolution, so they are counted out
# loud on every run whether the gate passes or fails.
BACKLOG=0
if [ -f "${ALLOWLIST}" ]; then
  BACKLOG="$(grep -c 'REAL-ORPHAN' "${ALLOWLIST}" 2>/dev/null || echo 0)"
  BACKLOG="$((BACKLOG - 2))"   # two mentions live in this file's own header prose
  [ "${BACKLOG}" -lt 0 ] && BACKLOG=0
fi
if [ "${BACKLOG}" -gt 0 ]; then
  echo "  ${YEL}BACKLOG: ${BACKLOG} acknowledged dark feature(s) parked in the allowlist${RST}"
  echo "  (allowlisted so this gate can enforce against NEW orphans — not because they are fine)"
fi

# COVERAGE disclosure — never a failure, always printed. These are the gate's known blind spot.
echo "----------------------------------------------------------------------------------"
if [ -n "${UNSWEPT}" ]; then
  echo "  ${BOLD}UNSWEPT${RST} — name too short/common for a word-boundary sweep to mean anything."
  echo '  NOT checked, NOT cleared. TopUpController.soc / .note were real #29 casualties of exactly'
  echo '  this shape. Triage by hand or with qualified matching.' 
  while IFS='|' read -r name file; do
    [ -n "${name}" ] || continue
    printf '    %-34s %s\n' "${name}" "${file#${REPO_ROOT}/}"
  done <<< "${UNSWEPT}"
fi

echo "=================================================================================="
if [ "${FAIL}" -eq 0 ]; then
  echo "UI-ORPHAN GATE: ${GRN}PASSED${RST} — every swept UI-facing declaration has a reader."
else
  echo "UI-ORPHAN GATE: ${RED}FAILED${RST} — ${UNALLOWED} orphan(s), ${STALE} stale allowlist entry/entries."
  echo "  Re-home the symbol (give it a screen), delete it, or allowlist it WITH a reason."
fi
[ "${LIST_ONLY}" = "1" ] && exit 0
exit "${FAIL}"
