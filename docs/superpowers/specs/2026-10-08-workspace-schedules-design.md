# Scheduled Claude runs in the workspace

## Goal

Recurring Claude tasks (first: the hourly pokemon-bot scrape health check)
run from the workspace pod on a schedule, survive restarts, may change code,
deployments and the production database, and are visible on the dashboard.
Today the check lives as an in-session `CronCreate` job in a laptop session,
with its scripts in the laptop's `~/.claude/projects` folder; it disappears
with that session.

## Approach

Schedules are declared in the homelab values and rendered into the workspace
ConfigMap, like repos and plugins. A cron runner inside the pod starts a fresh
headless Claude run per tick in the schedule's repo.

```yaml
workspace:
  schedules:
    pokemon-bot-scrape-health:
      repo: pokemon-bot
      cron: "31 * * * *"
      prompt: monitoring/scrape-health.md   # path inside the repo
      allow:                                # pre-approved on top of auto mode
        - Bash(monitoring/psql.sh:*)
        - Bash(monitoring/scrape_health.sh)
        - Bash(kubectl -n pokemon-bot:*)
        - Bash(glab mr:*)
        - Bash(git push:*)
```

Rejected:

- In-session schedules (`CronCreate`, `/loop`) in a workspace session: lost
  when the session or pod restarts, and every run grows one conversation.
- Claude cloud routines (`/schedule`): run on Anthropic's infrastructure and
  cannot reach the cluster or tailnet.
- A Kubernetes CronJob: a separate pod has neither the workspace's login nor
  its volume (ReadWriteOnce).

## Components

### Image (workspace project)

- `supercronic` (static binary, runs as uid 1000, reloads its crontab on
  change), pinned with a Renovate marker.
- `reconcile-schedules`: renders `/etc/workspace/schedules` (one JSON object
  per line: name, repo, cron, prompt, allow) into `~/.cache/workspace/crontab`;
  runs at boot and in the existing 30 s reconcile loop. Removing a schedule
  removes its crontab line; its logs stay.
- `run-schedule <name>`: takes a per-schedule `flock` (a tick that finds the
  previous run still going is skipped and logged as such), `cd`s into the
  repo, and runs
  `claude -p <prompt> --permission-mode auto --allowedTools <allow> --output-format stream-json`
  with the schedule's notes file appended to the prompt. Writes
  `~/.cache/workspace/schedules/<name>/runs/<timestamp>.jsonl`, `last.json`
  (start, end, exit code, result text) and keeps the last 200 runs. Usable by
  hand for an immediate run.
- Notes: `~/.cache/workspace/schedules/<name>/notes.md`. The wrapper tells the
  run to read it first and rewrite it last (known issues, open MRs, pending
  proposals). This replaces the "compare with what you already know from this
  session" memory of the in-session job.
- `workspace-status` gains `schedules`: name, repo, cron, next run, running,
  last start/end/exit, last result's first line.
- Scheduled runs fire the same session hooks, so a running schedule appears in
  the sessions table and counts as busy for `workspace-idle`; deploys wait for
  it like for any session.

### pokemon-bot repo

- `monitoring/scrape-health.md`: the current hourly prompt, adjusted:
  database writes are allowed when a fix needs them, under the rules below,
  instead of always proposing them.
- `monitoring/scrape_health.sh` and `monitoring/psql.sh` moved from the laptop
  folder (they only use `kubectl`; no credentials).
- `psql.sh write <db> <table> <where> <sql>`: copies the rows matching
  `<where>` from `<table>` into `monitoring_backup_<table>_<utc timestamp>`,
  then runs `<sql>` in the same transaction and prints the affected row count.
  The prompt requires every write to go through it and to report the SQL, row
  count and backup table in the run result and notes.

### Homelab repo

- `workspace.schedules` in values, rendered to the ConfigMap key `schedules`.
- Glance Workspace page: a Schedules widget (name, repo, next run, last run
  with outcome line and exit, running indicator).

## Creating and changing schedules

Add or edit an entry under `workspace.schedules` (or ask any workspace session
to, which opens the PR). After ArgoCD syncs, the ConfigMap updates in the pod
and the crontab follows within a minute; no restart. `run-schedule <name>`
runs one now.

## Behaviour on failure

| Event | Result |
|---|---|
| Pod restart | crontab regenerated at boot; a run cut off by a node failure is logged with no end time and the next tick runs normally |
| Run still going at the next tick | that tick is skipped and logged |
| Claude not logged in / network down | run ends with an error, shown as the last outcome |
| Action blocked by auto mode | the run reports it in its result instead of hanging |
| Deploy pending while a run is active | the idle guard waits for the run to finish |

## Security notes

- Scheduled runs act unattended with the pod's cluster-admin. The allow-list
  only pre-approves the listed commands; everything else is judged by auto
  mode's classifier.
- Database writes are reversible through the backup tables and recorded in
  logs and notes. Backup tables are left for the owner to drop.

## Verification

- Smoke test: a schedule in the ConfigMap appears in the crontab and
  disappears when removed; `run-schedule` with a stub `claude` writes
  `last.json`, skips while a previous run holds the lock, and passes the
  allow-list; `workspace-status` lists the schedule with its last outcome.
- `psql.sh write` against a scratch table: backup table created, change
  applied, both in one transaction.
- Live: `run-schedule pokemon-bot-scrape-health` once by hand, then the first
  scheduled tick; the Schedules widget shows both.
