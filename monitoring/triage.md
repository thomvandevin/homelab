# Homelab triage

Standing request from the owner: when the homelab reports a problem, find out
what is wrong and prepare the fix, so the owner only has to approve it from
the phone. This runs unattended every 10 minutes from the homelab workspace
(`workspace.schedules` in this repo), but only when `monitoring/check.sh`
reports something new.

What the check reports, one line each:

- `job <ns>/<name> <uid>`: a Kubernetes Job failed in the last day. Backups
  (`db-system` pg dumps and the R2 copy, closet's photo backup) only ever
  show up here.
- `crashloop <ns>/<pod> <uid>`: a container restarted 3+ times and is backing off.
- `node <name> notready`, `volume <ns>/<pvc> full` (85%+), `dns adguard down`.
- `home assistant weekly check <week>`: once a week, Monday after 09:00.

For each new line (compare with your notes; a line you already handled needs
nothing unless it changed):

1. Find the root cause first: `kubectl logs`, `describe`, events, the app's
   manifest in `apps/templates/`, and the app's own repo in `~/Projects/<repo>`.
   This repo's CLAUDE.md rules apply (placement, Glance, DHCP).
2. Without asking, and only these:
   - Rerun a GitLab CI job that failed with `runner_system_failure`, never one
     that failed its tests: `glab api -X POST projects/<project>/jobs/<id>/retry`.
   - Restart a deployment or statefulset in a known stuck state (a crash loop
     whose cause is outside its code, a leak such as a full /tmp), once per
     issue: `kubectl -n <ns> rollout restart <kind>/<name>`, then verify.
   Report each in your final message and in your notes.
3. Everything else becomes a proposal (the format is in the run's instructions
   below): a homelab change as a PR (`gh pr create`) from a git worktree, an
   app fix as an MR in its repo, a one-off command written out for the session
   to run. Never merge, never `kubectl apply` or delete anything (ArgoCD owns
   the cluster state), never touch volumes, PVCs, secrets or the `nixos/` tree
   on your own.
4. Home Assistant weekly check: read Home Assistant through the
   `home-assistant` connector, read tools only (live context, history, system
   health, system log): devices unavailable for a day or more, batteries under
   25%, pending updates, the age of the last backup. Propose what is worth
   doing (an update, a device to look at); change nothing. If the connector or
   those sensors are not available in this run, say so in the outcome.
5. A resolved problem disappears from the check by itself; note it as resolved.

No emdashes. No AI attribution in commits, PRs or MRs.
