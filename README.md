# Claude Code CLI in Docker

Docker container setup for running Claude Code CLI with subscription authentication.
Based on the [official devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

## Prerequisites

- Docker
- Claude Pro / Max subscription

## Setup

### 1. Build the image

```bash
cd ~/src/github.com/satomacoto/claude-docker
docker build -t claude-code .
```

### 2. First-time login

```bash
docker run -it --rm \
  -v claude-config:/home/node/.claude \
  claude-code claude login
```

A URL and code will be displayed. Open the URL in your browser and complete authentication.
Credentials are saved in the `claude-config` named volume.

### 3. Usage

Interactive mode:

```bash
docker run -it --rm \
  -v claude-config:/home/node/.claude \
  -v $(pwd):/workspace \
  claude-code claude
```

One-shot mode:

```bash
docker run --rm \
  -v claude-config:/home/node/.claude \
  -v $(pwd):/workspace \
  claude-code claude -p "Explain this project"
```

### 4. Docker Compose

```bash
docker compose run --rm claude
```

This automatically sets up the firewall and starts Claude Code with `--dangerously-skip-permissions`.

To use with a different project directory:

```bash
docker compose run --rm -v /path/to/project:/workspace claude
```

## Maintenance

```bash
# Check the volume
docker volume ls | grep claude

# Re-login (delete volume and login again)
docker volume rm claude-config
docker run -it --rm -v claude-config:/home/node/.claude claude-code claude login

# Update Claude Code
docker build --no-cache -t claude-code .
```

## Security notes

- The named volume isolates credentials from the host filesystem.
- The firewall script restricts outbound connections to whitelisted domains only.
- Do not use `--dangerously-skip-permissions` with untrusted repositories.

## References

- [Official devcontainer docs](https://docs.anthropic.com/en/docs/claude-code/devcontainer)
- [Official Dockerfile](https://github.com/anthropics/claude-code/blob/main/.devcontainer/Dockerfile)
