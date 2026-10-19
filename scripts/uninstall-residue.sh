#!/usr/bin/env bash
#
# uninstall-residue.sh — 5.5 Cut 2: remove the ONE root-owned residue the in-app uninstall can't.
# ============================================================================================
# The in-app teardown (Settings → Uninstall) restores the charge limit / Energy Mode / sleep-wake
# schedule, unregisters the daemon + login item, and removes the app's OWN user residue (its prefs
# domain + ~/Library/Application Support/BatteryApp). The ONLY thing it cannot delete is the helper's
# state directory under /Library/Application Support, which is owned by root (the privileged helper
# created it) — that needs sudo, so it lives here.
#
# On the in-app path, SMAppService tore down the launchd registration when the app unregistered the
# daemon — but that is true ONLY of that path. If the app was dragged to the Trash (or the dev bundle
# was deleted by `rm -rf build/`) the in-app teardown never ran, and the BTM registration is whatever
# `sfltool dumpbtm` says it is; this script neither checks nor changes it. This is state-dir removal
# ONLY. Nothing else.
#
# Preflight (see §2.H of the 2026-09 energy audit): this directory is the last on-disk trace that the
# app was ever here, and the ONE setting the app writes that has no System Settings surface at all is
# the `pmset repeat` sleep/wake schedule. Deleting the state dir while a repeating schedule is still
# programmed strands an invisible, machine-wide wake/sleep event with nothing left pointing at it, so
# we refuse and print the recovery command instead.

set -euo pipefail

# Repo-root cd (house convention — resolve regardless of the caller's cwd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

STATE_DIR="/Library/Application Support/com.example.batteryapp"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  printf 'uninstall-residue: this removes a root-owned directory — run with sudo:\n' >&2
  printf '  sudo %s\n' "scripts/uninstall-residue.sh" >&2
  exit 1
fi

# --- preflight: refuse while a repeating sleep/wake schedule is still programmed -------------------
# `pmset -g sched` prints a "Repeating power events:" block only when the single global repeat slot is
# occupied. No GUI anywhere exposes it, so if we wipe the last trace of the app with one still set, the
# owner has an invisible wake/sleep event and no breadcrumb. Escape hatch for a deliberate keep:
# ALLOW_REPEATING_SCHEDULE=1.
SCHED_OUT="$(pmset -g sched 2>/dev/null || true)"
if printf '%s\n' "${SCHED_OUT}" | grep -qi 'Repeating power events'; then
  if [ "${ALLOW_REPEATING_SCHEDULE:-0}" = "1" ]; then
    printf 'uninstall-residue: a repeating sleep/wake schedule is set; continuing (ALLOW_REPEATING_SCHEDULE=1).\n' >&2
  else
    printf 'uninstall-residue: REFUSING — a repeating sleep/wake schedule is still programmed:\n' >&2
    # Print ONLY the repeating block — the "Scheduled power events" list below it is OS alarms, noise.
    printf '%s\n' "${SCHED_OUT}" \
      | awk '/[Rr]epeating power events/{f=1; print; next} f && /^[^[:space:]]/ {f=0} f' \
      | sed 's/^/    /' >&2
    printf '\n' >&2
    printf '  pmset repeat is a single machine-wide slot with NO System Settings page. Removing this\n' >&2
    printf '  directory deletes the last on-disk trace of the app and leaves that event invisible.\n' >&2
    printf '  Clear it first:\n' >&2
    printf '    sudo pmset repeat cancel\n' >&2
    printf '  Verify with:\n' >&2
    printf '    pmset -g sched\n' >&2
    printf '  To keep the schedule deliberately and remove the directory anyway:\n' >&2
    printf '    sudo ALLOW_REPEATING_SCHEDULE=1 %s\n' "scripts/uninstall-residue.sh" >&2
    exit 1
  fi
fi

if [ -d "${STATE_DIR}" ]; then
  printf 'uninstall-residue: removing %s\n' "${STATE_DIR}"
  rm -rf "${STATE_DIR}"
else
  printf 'uninstall-residue: %s not present — nothing to remove.\n' "${STATE_DIR}"
fi

# Verify + report (list the parent so the absence is visible).
if [ -d "${STATE_DIR}" ]; then
  printf 'uninstall-residue: ERROR: %s still present after removal.\n' "${STATE_DIR}" >&2
  exit 1
fi
printf 'uninstall-residue: done. Parent listing:\n'
ls -la "/Library/Application Support" | grep -i "batteryapp\|com.example" || printf '  (no com.example.batteryapp entry remains)\n'
