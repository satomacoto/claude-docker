---
name: spawn-sbx-sandbox
description: Spawn a Claude Code teammate inside a Docker Sandboxes microVM (sbx) using a custom template that enables agent teams. Provides stronger isolation than spawn-docker-sandbox and uses Docker's official proxy-based network filtering (no CDN/IP issues). Use when the user wants strong isolation for a teammate and has the sbx CLI installed.
argument-hint: "[teammate-name]"
---

# Docker Sandboxes (sbx) Teammate

Spawn a Claude Code teammate inside a Docker Sandboxes microVM. Stronger isolation than `spawn-docker-sandbox` (microVM, proxy-based domain filtering, no iptables CDN issues), but requires the `sbx` CLI and a published custom template.

## Parse arguments

- arg1: teammate name (default: `sbx-worker`)

## Prerequisites

- `sbx` CLI installed: `brew install docker/tap/sbx`
- Logged in: `sbx login` (one-time)
- Default network policy set: `sbx policy set-default balanced` (one-time)
- Custom template `satomacoto/sandbox-templates:claude-code` published to Docker Hub. This template extends `docker/sandbox-templates:claude-code` with:
  - `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` enabled
  - A wrapper that symlinks the host's mounted `~/.claude/teams` and `~/.claude/tasks` into the sandbox's `$HOME/.claude/`
  - Playwright + Chromium pre-installed and `playwright-mcp` server auto-registered
  
  Source in this repo at `sbx-template/`.

> **Note**: sbx caches template images locally and does not auto-update them. If the template was rebuilt, either pin the new digest in `--template`, or run `sbx reset` to clear the cache (destructive: removes all sandboxes/secrets).

## Steps

1. **Ensure a team exists**:
   - If you already have a team, use that team name.
   - If not, create one with TeamCreate first.

2. **Get session info**:
   - Read `~/.claude/teams/{team-name}/config.json` to get the `leadSessionId`.

3. **Start the sandbox** in a tmux pane using Bash. The custom template is required so that `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set when claude starts:

   ```bash
   tmux split-window -h -P -F '#{pane_id}' "sbx run claude \
     --template docker.io/satomacoto/sandbox-templates:claude-code \
     --name {sandbox-name} \
     {cwd} \
     $HOME/.claude/teams \
     $HOME/.claude/tasks \
     -- --agent-id '{teammate-name}@{team-name}' \
        --agent-name '{teammate-name}' \
        --team-name '{team-name}' \
        --agent-color 'cyan' \
        --parent-session-id '{leadSessionId}' \
        --dangerously-skip-permissions \
        --teammate-mode in-process; echo '[Sandbox exited]'; read" > /tmp/sbx-pane-{teammate-name}
   ```

   Replace `{cwd}`, `{sandbox-name}`, `{teammate-name}`, `{team-name}`, and `{leadSessionId}` with actual values.

4. **First-time login**: If this is the first sandbox you spawn, claude will print "Not logged in" — send `/login` via tmux send-keys to trigger OAuth. The proxy handles auth flow and credentials are stored in the sandbox volume for next time. After login the sandbox restarts.

5. **Verify**: Send a test message via SendMessage. A reply confirms the teammate is ready.

## Network policy

Docker Sandboxes uses an HTTP/HTTPS proxy to enforce network access. The default `balanced` policy allows common dev services. To allow extra domains:

```bash
sbx policy allow network "race.netkeiba.com:443"
```

To allow all (research mode):

```bash
sbx policy set-default allow-all
```

Unlike iptables, the proxy filters by **domain name**, so CDN-hosted sites work without IP whitelisting.

## Note on config.json registration

Like `spawn-docker-sandbox`, sandbox-spawned teammates are not registered in `~/.claude/teams/{team-name}/config.json` members array. Message routing works via inbox files regardless.

## Fallback: sbx exec

If the custom template is unavailable, you can use the official `docker/sandbox-templates:claude-code-docker` template plus `sbx exec` to inject the env var manually:

```bash
# 1. Create sandbox (no agent yet)
sbx create claude --name {sandbox-name} {cwd} $HOME/.claude/teams $HOME/.claude/tasks

# 2. Symlink teams/tasks into agent home
sbx exec {sandbox-name} bash -c '
  mkdir -p $HOME/.claude
  ln -sfn /Users/sato/.claude/teams $HOME/.claude/teams
  ln -sfn /Users/sato/.claude/tasks $HOME/.claude/tasks
'

# 3. Start claude as a teammate via tmux
tmux split-window -h -P -F '#{pane_id}' "sbx exec -it {sandbox-name} \
  env CLAUDECODE=1 CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
  claude \
    --agent-id '{teammate-name}@{team-name}' \
    --agent-name '{teammate-name}' \
    --team-name '{team-name}' \
    --parent-session-id '{leadSessionId}' \
    --dangerously-skip-permissions \
    --teammate-mode in-process; echo '[exited]'; read" > /tmp/sbx-pane-{teammate-name}
```

## Shutdown

1. Send `shutdown_request` via SendMessage to the teammate.
2. After shutdown, close the pane and remove the sandbox:
   ```bash
   tmux kill-pane -t $(cat /tmp/sbx-pane-{teammate-name})
   sbx rm {sandbox-name}
   ```
