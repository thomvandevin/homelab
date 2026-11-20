#!/bin/bash
# Pre-check for the homelab triage schedule: one line per thing worth a Claude run,
# nothing when all is well. run-schedule starts Claude only when this output changes.
set -o pipefail

# The open problems alerts-watch already sent to Pushover (failed jobs, crash loops,
# nodes, full volumes, AdGuard), one per line with a stable key
{ kubectl -n alerts get configmap alerts-state -o jsonpath='{.data.keys}' && echo; } | sed '/^$/d' || exit 1

# Home Assistant's own weekly report goes out Monday 09:00; this line changes right after it
echo "home assistant weekly check $(date -d '-9 hours' +%G-W%V)"
