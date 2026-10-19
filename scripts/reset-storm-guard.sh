#!/usr/bin/env bash
# reset-storm-guard.sh — deliberately clear the energy-helper storm guard and relaunch it now.
# The daemon self-heals on its own (probationary backoff), so this is a CONVENIENCE to skip the cooldown
# after fixing a root cause — not a required recovery step. Requires sudo (root-owned state).
set -euo pipefail
STATE="/Library/Application Support/com.example.batteryapp/energyhelper-state.json"
SERVICE="system/com.example.batteryapp.energyhelper"
echo '{"crashCount":0,"backoffLevel":0}' | sudo tee "$STATE" >/dev/null
echo "storm guard cleared: $STATE"
sudo launchctl kickstart -k "$SERVICE"   # -k kills the running instance, then starts fresh → re-reads clean state, vends
echo "kickstarted: $SERVICE"
