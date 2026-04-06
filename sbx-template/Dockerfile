FROM docker/sandbox-templates:claude-code

# Enable Claude Code agent teams (required for --agent-id, --team-name flags)
ENV CLAUDECODE=1
ENV CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

# Install Playwright system dependencies and the @playwright/mcp server globally
USER root
RUN npm install -g @playwright/mcp && \
    npx -y playwright install-deps chromium

# Install Chromium browser as the agent user (browsers go under $HOME/.cache)
ENV PLAYWRIGHT_BROWSERS_PATH=/home/agent/.cache/ms-playwright
USER agent
RUN npx -y playwright install chromium

# Wrap claude so we can run init logic (symlink mounted teams/tasks dirs,
# register playwright MCP) before exec'ing the real claude binary.
USER root
COPY claude-wrapper.sh /usr/local/bin/claude-wrapper.sh
RUN chmod +x /usr/local/bin/claude-wrapper.sh && \
    mv /home/agent/.local/bin/claude /home/agent/.local/bin/claude-real && \
    ln -sf /usr/local/bin/claude-wrapper.sh /home/agent/.local/bin/claude && \
    chown -h agent:agent /home/agent/.local/bin/claude

USER agent
