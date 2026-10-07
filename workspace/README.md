# Workspace

Always-on Claude Code workspace: one `claude remote-control` server per repo
in `apps/values.yaml` (`workspace.repos`), driven from claude.ai/code or the
Claude desktop app. Reachable on the tailnet as `workspace` (SSH, port 22)
and `code` (code-server over HTTPS).

## One-time bootstrap

0. Before merging: set `workspace.gitUserEmail`, `githubToken` (PRs via `gh`)
   and `gitlabToken` (MRs via `glab`) in `apps/secrets.yaml.dec`, re-encrypt,
   and list the repos under `workspace.repos` in `apps/values.yaml`. After the
   first image build, make the `workspace` package public on GitHub so the
   cluster can pull it.
1. Register the pod's git key with GitLab and GitHub:
   ```bash
   kubectl -n workspace logs workspace-0 | grep 'git public key'
   ```
2. Sign in to claude.ai (prints a URL; open it anywhere, paste the code back):
   ```bash
   kubectl -n workspace exec -it workspace-0 -- claude auth login
   ```
3. Answer the one-time prompts in each repo window (`Enable Remote Control?`,
   `Trust <directory>?`), then detach with `Ctrl-b d`:
   ```bash
   kubectl -n workspace exec -it workspace-0 -- tmux attach
   ```
   Switch windows with `Ctrl-b n`. Each window then shows its session URL.
4. Copy the sops age key so sessions can edit `apps/secrets.yaml`, and the
   global Claude instructions (the pod already seeds
   `includeCoAuthoredBy: false` in `~/.claude/settings.json`):
   ```bash
   ssh dev@workspace 'mkdir -p ~/.config/sops/age'
   scp key.txt dev@workspace:~/.config/sops/age/keys.txt
   scp ~/.claude/CLAUDE.md dev@workspace:~/.claude/CLAUDE.md
   ```

Everything above lives on the `home` volume; pod restarts need none of it.

## Day to day

- Sessions: claude.ai/code, one per repo, named after the repo.
- Editor: VS Code Remote-SSH to `dev@workspace`, or `https://code.<tailnet>.ts.net`.
- Add a repo: add it under `workspace.repos`, ArgoCD restarts the pod, the
  loop clones it and a new window appears. Answer the trust prompt once.
- Attach to the servers: `kubectl -n workspace exec -it workspace-0 -- tmux attach`.
- Claude Code updates itself in `~/.local`; tool versions in the image are
  bumped by Renovate.
- Local check of the image: `./workspace/smoke-test.sh` (needs Docker).

## Failure modes

| Event | Result |
|---|---|
| Pod or node restart | servers restart; sessions younger than 4 h resume, older ones are archived |
| Anthropic unreachable > 10 min | the server exits and the loop restarts it every 10 s |
| A session crashes | it is re-served on the next message from the app |
| Login expired | the window shows the error; repeat bootstrap step 2 |
