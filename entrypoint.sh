#!/bin/bash
# Git config (from environment variables)
if [ -n "$GIT_USER_NAME" ]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi

# Register default MCP servers (skip if already configured)
if ! claude mcp get playwright &>/dev/null; then
  claude mcp add playwright --scope user --transport stdio -- playwright-mcp --headless --browser chromium
fi

# Setup firewall
sudo /usr/local/bin/init-firewall.sh

exec "$@"
