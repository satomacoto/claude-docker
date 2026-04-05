#!/bin/bash
# Git config (from environment variables)
if [ -n "$GIT_USER_NAME" ]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi

# Enable Agent Teams by default
SETTINGS_FILE="$CLAUDE_CONFIG_DIR/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi
tmp=$(jq '.env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"' "$SETTINGS_FILE")
echo "$tmp" > "$SETTINGS_FILE"

# Register default MCP servers (skip if already configured)
if ! claude mcp get playwright &>/dev/null; then
  claude mcp add playwright --scope user --transport stdio -- playwright-mcp --headless --browser chromium
fi

# Setup firewall
sudo ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-}" /usr/local/bin/init-firewall.sh

exec "$@"
