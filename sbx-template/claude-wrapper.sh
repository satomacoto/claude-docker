#!/bin/bash
# Wrapper that runs sbx-specific init logic before exec'ing the real claude.
#
# When sbx mounts ~/.claude/teams as an additional workspace, it appears
# at the host's absolute path (e.g. /Users/foo/.claude/teams). Claude Code
# expects them under $HOME/.claude/{teams,tasks}, so we symlink them.

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

exec /home/agent/.local/bin/claude-real "$@"
