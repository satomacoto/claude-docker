---
name: spawn-docker-sandbox
description: Spawn a sandboxed Claude Code teammate running inside a Docker container (claude-code image) with optional iptables firewall. Use when the user wants to run untrusted tasks in isolation, or when any teammate should be confined to a container.
argument-hint: "[teammate-name]"
---

# Docker Sandbox Teammate

Spawn a Claude Code teammate inside a Docker container for sandboxed execution.

## Parse arguments

- arg1: teammate name (default: `docker-sandbox`)

## Prerequisites

- Docker image `claude-code` must be built (`docker images claude-code` to check)
- Docker volume `claude-config` must have valid authentication (`docker run --rm -v claude-config:/home/node/.claude claude-code claude auth status`)
- If auth is missing, tell the user to run: `! docker run -it --rm -v claude-config:/home/node/.claude claude-code claude login`

## Steps

1. **Ensure a team exists**:
   - If you already have a team, use that team name.
   - If not, create one with TeamCreate first. Use the returned team name.

2. **Get session info**:
   - Read `~/.claude/teams/{team-name}/config.json` to get the `leadSessionId`.

3. **Start the Docker container** in a tmux pane using Bash:
   ```bash
   tmux split-window -h -P -F '#{pane_id}' "docker run -it --rm \
     -v claude-config:/home/node/.claude \
     -v $HOME/.claude/teams:/home/node/.claude/teams \
     -v $HOME/.claude/tasks:/home/node/.claude/tasks \
     -v {cwd}:/workspace \
     -e CLAUDECODE=1 \
     -e CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
     claude-code claude \
       --agent-id '{teammate-name}@{team-name}' \
       --agent-name '{teammate-name}' \
       --team-name '{team-name}' \
       --agent-color 'blue' \
       --parent-session-id '{leadSessionId}' \
       --dangerously-skip-permissions \
       --teammate-mode in-process; echo '[Container exited]'; read" > /tmp/docker-sandbox-pane-{teammate-name} && sleep 15 && cat /tmp/docker-sandbox-pane-{teammate-name}
   ```

   Replace `{cwd}` with the actual working directory, `{team-name}` with the team name, `{teammate-name}` with the teammate name, and `{leadSessionId}` with the leader's session ID from the config.

4. **Wait for startup**: The container needs ~15-20 seconds to initialize (entrypoint, firewall setup, Claude Code startup). Verify by capturing the tmux pane output and checking for the `@{teammate-name}` prompt.

5. **Confirm**: `{teammate-name}` is ready. Use SendMessage to assign tasks.

## Firewall

By default, the container starts **without** the iptables firewall (no `--cap-add NET_ADMIN`). To enable the firewall for stricter isolation, add `--cap-add NET_ADMIN` to the `docker run` command. The firewall restricts outbound connections to whitelisted domains only (GitHub, npm, Anthropic API). Additional domains can be allowed via `-e ALLOWED_DOMAINS=domain1,domain2`.

## Shutdown

1. Send `shutdown_request` via SendMessage to the teammate.
2. After shutdown, close the pane:
   ```bash
   tmux kill-pane -t $(cat /tmp/docker-sandbox-pane-{teammate-name})
   ```
