FROM docker/sandbox-templates:claude-code

# Enable Claude Code agent teams (required for --agent-id, --team-name flags)
ENV CLAUDECODE=1
ENV CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

USER root

# Wrap claude so we can run init logic (symlink mounted teams/tasks dirs)
# before exec'ing the real claude binary.
COPY claude-wrapper.sh /usr/local/bin/claude-wrapper.sh
RUN chmod +x /usr/local/bin/claude-wrapper.sh && \
    mv /home/agent/.local/bin/claude /home/agent/.local/bin/claude-real && \
    ln -sf /usr/local/bin/claude-wrapper.sh /home/agent/.local/bin/claude && \
    chown -h agent:agent /home/agent/.local/bin/claude

USER agent
