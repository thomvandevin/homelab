# Workspace schedules: implementation plan

**Spec:** `docs/superpowers/specs/2026-10-08-workspace-schedules-design.md`
**Execution:** inline, test first; the workspace project's `smoke-test.sh` is the test harness.

## Global constraints

- Runs are `claude -p` with `--permission-mode auto` and the schedule's `allow` list; never API keys.
- Scheduled runs never overlap (per-schedule `flock`); a skipped tick is logged.
- Schedules apply live from the ConfigMap; no pod restart.
- No AI attribution in commits or MRs.

## Task 1: workspace image (GitLab project `workspace`)

- Smoke test first:
  - schedule line in the `schedules` config file appears in `~/.cache/workspace/crontab` and disappears when removed;
  - `run-schedule` with a stub `claude` records its arguments (prompt contains the repo prompt file and the notes, `--permission-mode auto`, `--allowedTools` with the allow list), writes `last.json` with exit code and result line, keeps the notes path;
  - a second `run-schedule` while the first holds the lock exits 0 and logs a skip;
  - `workspace-status` lists the schedule with `last_result` and `next_run`;
  - supercronic is running and picks up the crontab.
- Then: `supercronic` (pinned, Renovate marker), `reconcile-schedules`, `run-schedule`, status fields, entrypoint wiring.

## Task 2: pokemon-bot (GitLab project `pokemon-bot`)

- `monitoring/scrape-health.md`, `monitoring/scrape_health.sh`, `monitoring/psql.sh` with `write` mode.
- Test `psql.sh write` against a scratch table in a throwaway Postgres container: backup table created, change applied, one transaction (a failing statement leaves neither).
- MR, merged once green.

## Task 3: homelab

- `workspace.schedules` value and ConfigMap key `schedules` (one JSON object per line).
- Glance Schedules widget on the Workspace page; check it renders with a sample status as before.
- PR, merged.

## Task 4: live

- `run-schedule pokemon-bot-scrape-health` by hand once, read the result, then watch the first scheduled tick and the widget.
- Tell the owner to stop the laptop session's `CronCreate` job.
