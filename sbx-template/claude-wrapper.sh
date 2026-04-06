#!/bin/bash
# Wrapper that runs sbx-specific init logic before exec'ing the real claude.
#
# - Symlinks the host's mounted ~/.claude/teams and ~/.claude/tasks (which sbx
#   places at the host's absolute path) into $HOME/.claude/ so Claude Code's
#   inbox poller finds them.
# - Registers the playwright MCP server in user scope on first run.

set -e

mkdir -p "$HOME/.claude"

for entry in teams tasks; do
  if [ -e "$HOME/.claude/$entry" ]; then
    continue
  fi
  # Find any mounted dir ending in /.claude/$entry
  mounted=$(find / -maxdepth 4 -type d -name "$entry" -path "*/.claude/$entry" 2>/dev/null | head -1)
  if [ -n "$mounted" ]; then
    ln -sfn "$mounted" "$HOME/.claude/$entry"
  fi
done

# Register playwright MCP server (skip if already configured)
if ! /home/agent/.local/bin/claude-real mcp get playwright &>/dev/null; then
  /home/agent/.local/bin/claude-real mcp add playwright --scope user --transport stdio -- playwright-mcp --headless --browser chromium &>/dev/null || true
fi

exec /home/agent/.local/bin/claude-real "$@"
