#!/usr/bin/env bash
#
# smc-dead-gate.sh — Sprint 3.7 STAGE 1 "SMC-DEAD" build/test gate (SPEC 02-SPEC-phase-37 sec 5).
# =============================================================================================
# Asserts — as a NON-BYPASSABLE failure (exit non-zero) — that the privileged ENERGY helper
# carries ZERO SMC / charge-inhibit capability. This is what converts the v3 "REPURPOSE" ruling
# from "trust the strip-down" into "proven absent" (SPEC sec 0/5).
#
# FIVE CHECKS (any hit => FAIL the build/test):
#   (a) project.yml: the privileged `type: tool` target's source-membership excludes helper/SMC,
#       the charge-inhibit Control logic, and the SWIFT_OBJC_BRIDGING_HEADER. NOTE: (a) is a cheap
#       best-effort MANIFEST sanity check — it is evadable by renaming a charge source (no `SMC` in the
#       path). The AUTHORITATIVE proof-of-absence is (b)+(c)+(d) on the built binary; do NOT weaken
#       those on the assumption (a) covers source membership.
#   (b) the BUILT helper binary contains no SMC SYMBOLS or key strings (nm + strings):
#       AppleSMC, the SMC 4-char keys (CHTE/CH0B/CH0C/BCLM/CHWA), ba_smc_*, LiveSMC,
#       SMCInterface, SMCKeys, SMCShim, SMCKey(Info), ChargeInhibit(Engine), setChargeInhibit,
#       restoreNormalCharging, reconcileToAllow, ChargeControlService/State, ChargeMechanism.
#   (c) the binary LINKS no SMC-bearing framework (otool -L): the energy helper is Process-only
#       (pmset / powermetrics) and must NOT link IOKit (the only reach to AppleSMC) nor a STRONG
#       libswiftIOKit nor anything named AppleSMC. (A *weak* libswiftIOKit is the unavoidable Swift
#       toolchain default and is allowed; strong = actual IOKit use. Guards a transitive AppleSMC pull.)
#   (d) NO dynamic loading at all: ANY dlopen/dlsym/dlmopen symbol-or-string is a hard FAIL (plus any
#       AppleSMC literal). The Process-only helper never dynamically loads; forbidding the MECHANISM
#       closes the runtime-computed/obfuscated-path bypass that a literal-string scan cannot catch.
#   (e) the gate's own WIRING is present + always-run: project.yml's tool target must invoke
#       scripts/smc-dead-gate.sh as a postBuildScripts phase with basedOnDependencyAnalysis:false, so
#       the enforcement hook cannot be silently deleted by editing project.yml + regenerating.
#
# Checks (a)-(e) are the SMC-DEAD proof — they must remain 5/5 PASS (SMC proven absent). A3 adds:
#   (f) SPAWN HARDENING (Sprint 3.7 fix A3 — NOT an SMC check): the privileged child spawn must stay
#       BOUNDED (timeout → SIGTERM → grace → SIGKILL → waitpid-reap) and ISOLATED (posix_spawn with
#       POSIX_SPAWN_CLOEXEC_DEFAULT, no shell). Guards against a silent revert to an unbounded
#       Process()/shell spawn. Source markers present + binary links posix_spawn + no shell path literal.
#
# Usage:
#   smc-dead-gate.sh [HELPER_BINARY] [PROJECT_YML]
# In an Xcode run-script build phase, both default from the environment:
#   HELPER_BINARY = $BUILT_PRODUCTS_DIR/$EXECUTABLE_PATH   (falls back to $TARGET_BUILD_DIR/$EXECUTABLE_NAME)
#   PROJECT_YML   = $SRCROOT/project.yml                    (falls back to ./project.yml)
# Standalone (manual / CI / negative-control), pass them explicitly.
#
# Exit 0 = all four checks PASS (SMC proven absent). Non-zero = a check FAILED (SMC present).

set -u
export LC_ALL=C

# ---------------------------------------------------------------------------- inputs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --membership-only runs JUST check (a) (project.yml source membership) — host-app-free, no binary
# needed (used by the CI/unit test). Otherwise (a)-(d) all run against the built helper binary.
MEMBERSHIP_ONLY=0
if [ "${1:-}" = "--membership-only" ]; then MEMBERSHIP_ONLY=1; shift; fi

if [ "${MEMBERSHIP_ONLY}" = "1" ]; then
  HELPER_BINARY=""
  PROJECT_YML="${1:-${SRCROOT:-${REPO_ROOT}}/project.yml}"
else
  HELPER_BINARY="${1:-}"
  if [ -z "${HELPER_BINARY}" ]; then
    if [ -n "${BUILT_PRODUCTS_DIR:-}" ] && [ -n "${EXECUTABLE_PATH:-}" ]; then
      HELPER_BINARY="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}"
    elif [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${EXECUTABLE_NAME:-}" ]; then
      HELPER_BINARY="${TARGET_BUILD_DIR}/${EXECUTABLE_NAME}"
    fi
  fi
  PROJECT_YML="${2:-${SRCROOT:-${REPO_ROOT}}/project.yml}"
fi

# ---------------------------------------------------------------------------- helpers
FAILS=0
declare -a RESULTS=()
red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
record() { # $1=check id  $2=PASS|FAIL  $3=detail
  RESULTS+=("$1|$2|$3")
  if [ "$2" = "FAIL" ]; then FAILS=$((FAILS + 1)); fi
}

# The forbidden SMC / charge-inhibit tokens. Deliberately SPECIFIC (high precision) so the FROZEN
# native path app/ChargeControl (legitimately contains the substring "Charge") never false-positives.
SMC_TOKENS_RE='AppleSMC|ba_smc|LiveSMC|SMCInterface|SMCKeys|SMCShim|SMCKey|ChargeInhibit|setChargeInhibit|restoreNormalCharging|reconcileToAllow|ChargeControlService|ChargeControlState|ChargeMechanism|SMCKeyInfo'
SMC_KEYS_RE='CHTE|CH0B|CH0C|BCLM|CHWA'
# project.yml forbidden membership tokens (helper-specific filenames + the bridging header).
YML_TOKENS_RE='helper/SMC|SWIFT_OBJC_BRIDGING_HEADER|ChargeInhibitEngine|ChargeControlService|ChargeControlState|ChargeMechanism|SafetyPolicy|IOKitTelemetry|EngineSeams|SMCInterface|SMCKeys|SMCShim|LiveSMC'

echo "=== SMC-DEAD gate (Sprint 3.7 STAGE 1) ==========================================="
echo "  helper binary : ${HELPER_BINARY:-<none>}"
echo "  project.yml   : ${PROJECT_YML}"
echo "----------------------------------------------------------------------------------"

# ---------------------------------------------------------------------------- (a) source membership
# Extract the privileged `type: tool` target block from project.yml (rename-robust), then assert it
# carries none of the forbidden membership tokens. Also assert helper/SMC + bridging header appear
# NOWHERE in project.yml (the test target must not pull them either).
if [ ! -f "${PROJECT_YML}" ]; then
  record a FAIL "project.yml not found at ${PROJECT_YML}"
else
  # Isolate the privileged `type: tool` target block (rename-robust; single header rule so the
  # block-transition print is live; exit at the first/only tool target).
  TOOL_BLOCK="$(awk '
    /^  [A-Za-z0-9_.]+:[[:space:]]*$/ { if (inblk && istool) { print blk; exit } inblk=1; blk=$0 "\n"; istool=0; next }
    inblk { blk = blk $0 "\n"; if ($0 ~ /type:[[:space:]]*tool/) istool=1 }
    END { if (inblk && istool) print blk }
  ' "${PROJECT_YML}")"

  # Primary, unambiguous signal: helper/SMC + the bridging header must appear NOWHERE in project.yml
  # (neither the tool target nor the test target may pull them). Plus the tool block (if isolated)
  # must carry none of the helper-specific charge-inhibit filenames.
  # Strip YAML comments first so a comment that MENTIONS a token (e.g. "# NO SWIFT_OBJC_BRIDGING_HEADER")
  # never trips the check — only an actual source path / setting assignment counts.
  hit_global="$(sed 's/#.*$//' "${PROJECT_YML}" | grep -nE 'helper/SMC|SWIFT_OBJC_BRIDGING_HEADER' || true)"
  hit_block=""
  if [ -n "${TOOL_BLOCK}" ]; then
    hit_block="$(printf '%s\n' "${TOOL_BLOCK}" | sed 's/#.*$//' | grep -nE "${YML_TOKENS_RE}" || true)"
  fi
  if [ -n "${hit_global}" ] || [ -n "${hit_block}" ]; then
    record a FAIL "global SMC/bridging: [$(printf '%s' "${hit_global}" | tr '\n' ';')] ; tool-block: [$(printf '%s' "${hit_block}" | tr '\n' ';')]"
  elif [ -z "${TOOL_BLOCK}" ]; then
    record a FAIL "could not isolate a 'type: tool' target block to verify membership"
  else
    record a PASS "tool target + project.yml exclude SMC/charge-inhibit sources + bridging header"
  fi
fi

# Binary-dependent checks (b)(c)(d) require the built helper. If absent, that's a FAIL in a build
# phase (we must have just built it); standalone callers must pass a path.
if [ "${MEMBERSHIP_ONLY}" = "1" ]; then
  echo "  (membership-only mode: binary checks b/c/d skipped)"
elif [ -z "${HELPER_BINARY}" ] || [ ! -f "${HELPER_BINARY}" ]; then
  record b FAIL "helper binary not found (cannot scan symbols)"
  record c FAIL "helper binary not found (cannot scan links)"
  record d FAIL "helper binary not found (cannot scan dlopen)"
else
  # ------------------------------------------------------------------------ (b) symbols/strings
  nm_hits="$(nm "${HELPER_BINARY}" 2>/dev/null | grep -aiE "${SMC_TOKENS_RE}" || true)"
  str_hits="$(strings - "${HELPER_BINARY}" 2>/dev/null | grep -aE "${SMC_TOKENS_RE}" || true)"
  # SMC 4-char keys: match as standalone tokens to avoid matching inside unrelated words.
  key_hits="$(strings - "${HELPER_BINARY}" 2>/dev/null | grep -aoE "${SMC_KEYS_RE}" | sort -u || true)"
  b_n=$(( $(printf '%s' "${nm_hits}"  | grep -c . ) + $(printf '%s' "${str_hits}" | grep -c . ) + $(printf '%s' "${key_hits}" | grep -c . ) ))
  if [ "${b_n}" -gt 0 ]; then
    record b FAIL "$(printf '%s' "${nm_hits}" | grep -c .) nm + $(printf '%s' "${str_hits}" | grep -c .) string + $(printf '%s' "${key_hits}" | grep -c .) key hits (e.g. $(printf '%s' "${key_hits}" | tr '\n' ' ')$(printf '%s' "${str_hits}" | head -1))"
  else
    record b PASS "no SMC symbols, key strings, or charge-inhibit identifiers in binary"
  fi

  # ------------------------------------------------------------------------ (c) framework links
  # The true signals that the binary can reach AppleSMC: a link to IOKit.framework (the system
  # framework exposing the AppleSMC user client), an AppleSMC link, or a NON-weak libswiftIOKit
  # (the Swift IOKit overlay linked strongly = actual IOKit usage). A *weak* libswiftIOKit is an
  # UNAVOIDABLE toolchain default present in every Swift macOS executable (verified: a trivial
  # `import Foundation` tool links it too) and must NOT be treated as IOKit usage. When code actually
  # uses IOKit, the linker pulls IOKit.framework + a strong libswiftIOKit (as the SMC-bearing baseline
  # did); the energy helper (Process-only: pmset/powermetrics) pulls neither.
  link_lines="$(otool -L "${HELPER_BINARY}" 2>/dev/null | tail -n +2)"   # drop the binary-name header line
  hard_hits="$(printf '%s\n' "${link_lines}" | grep -aiE 'IOKit\.framework|AppleSMC' || true)"
  swiftiokit_strong="$(printf '%s\n' "${link_lines}" | grep -ai 'libswiftIOKit' | grep -aiv 'weak' || true)"
  if [ -n "${hard_hits}" ] || [ -n "${swiftiokit_strong}" ]; then
    record c FAIL "binary links SMC-bearing framework(s): $(printf '%s%s' "${hard_hits}" "${swiftiokit_strong}" | sed 's/^[[:space:]]*//' | tr '\n' ';')"
  else
    record c PASS "no IOKit.framework / AppleSMC / strong-libswiftIOKit link (only the weak toolchain-default overlay)"
  fi

  # ------------------------------------------------------------------------ (d) dynamic loading
  # The energy helper is Process-only (pmset/powermetrics via Foundation.Process) and legitimately
  # never dynamically loads anything — the clean binary has ZERO dlopen/dlsym. Treat ANY
  # dlopen/dlsym/dlmopen as a hard FAIL: it is THE runtime-load bypass vector, and a runtime-computed
  # or obfuscated path defeats a static string scan — so we forbid the MECHANISM, not just literals.
  dlopen_ref="$( { nm "${HELPER_BINARY}" 2>/dev/null; strings - "${HELPER_BINARY}" 2>/dev/null; } | grep -aiE 'dlopen|dlsym|dlmopen' || true)"
  applesmc_lit="$(strings - "${HELPER_BINARY}" 2>/dev/null | grep -aiE 'AppleSMC' || true)"
  if [ -n "${dlopen_ref}" ]; then
    record d FAIL "dynamic loading present (dlopen/dlsym) — the Process-only helper must never dlopen (runtime-load bypass vector)"
  elif [ -n "${applesmc_lit}" ]; then
    record d FAIL "AppleSMC path literal present in binary"
  else
    record d PASS "no dynamic loading (zero dlopen/dlsym) and no AppleSMC literal"
  fi
fi

# ---------------------------------------------------------------------------- (e) gate wiring guard
# The .xcodeproj is gitignored + regenerated from project.yml, so the enforcement hook lives ONLY in
# project.yml. Assert the tool target wires this script as an ALWAYS-RUN postBuild phase, so it cannot
# be silently removed (edit project.yml + regenerate) without a check failing. Runs in every mode
# (incl. --membership-only) since it is a project.yml check.
if [ -z "${TOOL_BLOCK:-}" ]; then
  record e FAIL "no 'type: tool' target block to verify gate wiring"
else
  blk_nc="$(printf '%s\n' "${TOOL_BLOCK}" | sed 's/#.*$//')"
  has_phase=no;  printf '%s\n' "${blk_nc}" | grep -qE 'postBuildScripts:'                       && has_phase=yes
  has_script=no; printf '%s\n' "${blk_nc}" | grep -qE 'smc-dead-gate\.sh'                        && has_script=yes
  has_always=no; printf '%s\n' "${blk_nc}" | grep -qE 'basedOnDependencyAnalysis:[[:space:]]*false' && has_always=yes
  if [ "${has_phase}" = yes ] && [ "${has_script}" = yes ] && [ "${has_always}" = yes ]; then
    record e PASS "tool target wires smc-dead-gate.sh as an always-run postBuild phase"
  else
    record e FAIL "gate wiring missing/weak: postBuildScripts=${has_phase} smc-dead-gate.sh=${has_script} basedOnDependencyAnalysis:false=${has_always}"
  fi
fi

# ---------------------------------------------------------------------------- (f) spawn hardening (A3)
# Sprint 3.7 fix A3 (Grok 1 BLOCKER + MAJORs): the privileged child spawn must stay BOUNDED (hard
# timeout → SIGTERM → grace → SIGKILL → waitpid-reap, all paths) and ISOLATED (posix_spawn with
# POSIX_SPAWN_CLOEXEC_DEFAULT, no shell, fixed argv). This is NOT an SMC check — it guards the spawn
# from a silent revert to an unbounded Process()/shell spawn. Checks (a)-(e) remain the SMC proof (5/5).
SERVICE_SRC="$(dirname "${PROJECT_YML}")/helper/XPC/EnergyHelperService.swift"
f_fail=""
if [ ! -f "${SERVICE_SRC}" ]; then
  f_fail="${f_fail} EnergyHelperService.swift-not-found"
else
  src_nc="$(sed 's|//.*$||' "${SERVICE_SRC}")"
  # bounded-lifecycle + isolation markers must be PRESENT
  for marker in posix_spawn POSIX_SPAWN_CLOEXEC_DEFAULT SIGTERM SIGKILL waitpid; do
    printf '%s\n' "${src_nc}" | grep -qF "${marker}" || f_fail="${f_fail} missing-marker:${marker}"
  done
  # shell-spawn reverts must be ABSENT from the source
  shell_src="$(printf '%s\n' "${src_nc}" | grep -aoE '/bin/(sh|bash|zsh)|popen\(|system\(' | sort -u || true)"
  [ -z "${shell_src}" ] || f_fail="${f_fail} shell-spawn-in-source:[$(printf '%s' "${shell_src}" | tr '\n' ';')]"
fi
# Binary checks (when available): the hardened spawn is actually linked; no shell path literal.
if [ "${MEMBERSHIP_ONLY}" != "1" ] && [ -n "${HELPER_BINARY}" ] && [ -f "${HELPER_BINARY}" ]; then
  nm "${HELPER_BINARY}" 2>/dev/null | grep -qE ' _posix_spawn$' || f_fail="${f_fail} binary-not-linking-posix_spawn"
  shell_lit="$(strings - "${HELPER_BINARY}" 2>/dev/null | grep -aoxE '/bin/(sh|bash|zsh)' | sort -u || true)"
  [ -z "${shell_lit}" ] || f_fail="${f_fail} shell-path-literal:[$(printf '%s' "${shell_lit}" | tr '\n' ';')]"
fi
if [ -n "${f_fail}" ]; then
  record f FAIL "spawn hardening regressed:${f_fail}"
else
  record f PASS "child spawn bounded (timeout/SIGTERM/SIGKILL/waitpid) + isolated (posix_spawn CLOEXEC, no shell)"
fi

# ---------------------------------------------------------------------------- report
echo "  check  result  detail"
echo "  -----  ------  ----------------------------------------------------------------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r id res det <<<"$r"
  if [ "${res}" = "PASS" ]; then mark="$(green PASS)"; else mark="$(red FAIL)"; fi
  printf "  (%s)    %s    %s\n" "${id}" "${mark}" "${det}"
done
echo "=================================================================================="

if [ "${FAILS}" -gt 0 ]; then
  echo "SMC-DEAD GATE: $(red "FAILED") — ${FAILS} check(s) detected SMC/charge-inhibit content. Build/test must fail."
  exit 1
fi
echo "SMC-DEAD GATE: $(green "PASSED") — SMC capability proven absent from the energy helper."
exit 0
