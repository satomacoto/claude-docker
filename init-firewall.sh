#!/bin/bash
# Set up squid as a forward proxy with a domain allowlist, then use iptables
# (if NET_ADMIN is available) to force all non-proxy outbound traffic to drop.
#
# This replaces the previous IP-based iptables approach. Domain-based filtering
# works correctly with CDNs (no stale IP problem) and is much easier to manage.

set -euo pipefail

IFS=$'\n\t'

DOMAINS_FILE=/etc/squid/allowed_domains.txt
mkdir -p /etc/squid /var/log/squid /var/cache/squid
chown proxy:proxy /var/log/squid /var/cache/squid

if [ "${ALLOW_ALL_DOMAINS:-}" = "1" ]; then
  # In fully-open mode, the allowed_domains ACL is not consulted by
  # http_access, but squid still parses its source file at startup.
  # Write a minimal safe stub so the ACL stays well-formed regardless of
  # any ALLOWED_DOMAINS value the user may have set in .env.
  cat > "$DOMAINS_FILE" << 'EOF'
# ALLOW_ALL_DOMAINS=1: allowlist unused
.invalid
EOF
else
  # Default allowlist: developer essentials (GitHub, npm, PyPI, Anthropic, etc.)
  # Note: squid's dstdomain ACL treats a leading dot as "this domain and all
  # subdomains", and errors if you list both `foo.com` and `.foo.com`. So each
  # entry must be either a bare hostname OR `.parent` — not both.
  cat > "$DOMAINS_FILE" << 'EOF'
# Version control and code hosting
.github.com
.githubusercontent.com
.gitlab.com
.bitbucket.org

# Package managers
.npmjs.org
.npmjs.com
.yarnpkg.com
.pypi.org
.pythonhosted.org
.rubygems.org
.crates.io
.goproxy.io
proxy.golang.org

# Python / Rust toolchains
.astral.sh
sh.rustup.rs
.rust-lang.org

# Anthropic + Claude Code
.anthropic.com
.claude.ai
.claude.com
sentry.io
.statsig.com

# OS package repos
.debian.org
.ubuntu.com
EOF

  # Append extras from ALLOWED_DOMAINS (comma-separated).
  # Leading dot means "domain and subdomains"; bare hostname means exact match.
  #
  # Squid rejects an ACL that contains both `foo.com` and `.foo.com`, so we
  # auto-dedupe on insert: dot-prefix is broader and always wins. A bare
  # hostname that a `.X` entry already covers is silently skipped; a new
  # `.X` entry evicts any previously written bare `X`.
  if [ -n "${ALLOWED_DOMAINS:-}" ]; then
    echo "" >> "$DOMAINS_FILE"
    echo "# From ALLOWED_DOMAINS env var" >> "$DOMAINS_FILE"
    IFS=',' read -ra EXTRA_DOMAINS <<< "$ALLOWED_DOMAINS"
    for domain in "${EXTRA_DOMAINS[@]}"; do
      domain=$(echo "$domain" | xargs)  # trim whitespace
      [ -z "$domain" ] && continue

      if [[ "$domain" == .* ]]; then
        # Dot-prefix entry: evict any existing bare form
        bare="${domain#.}"
        if grep -qxF "$bare" "$DOMAINS_FILE"; then
          grep -vxF "$bare" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp"
          mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
          echo "# (dropped bare '$bare' in favor of '$domain')" >> "$DOMAINS_FILE"
        fi
      else
        # Bare entry: skip if a dot-prefix version already covers it
        if grep -qxF ".$domain" "$DOMAINS_FILE"; then
          echo "# (skipped '$domain' — already covered by '.$domain')" >> "$DOMAINS_FILE"
          continue
        fi
      fi

      # Skip exact duplicate
      if grep -qxF "$domain" "$DOMAINS_FILE"; then
        continue
      fi

      echo "$domain" >> "$DOMAINS_FILE"
    done
  fi
fi

echo "Allowed domains written to $DOMAINS_FILE"

# Toggle squid between allowlist and fully-open mode based on ALLOW_ALL_DOMAINS.
# We rewrite squid.conf in place (idempotent) so flipping the env var between
# runs switches modes without rebuilding the image.
if [ "${ALLOW_ALL_DOMAINS:-}" = "1" ]; then
  echo "ALLOW_ALL_DOMAINS=1: squid will allow all destinations"
  sed -i -E 's|^http_access allow (allowed_domains\|all)$|http_access allow all|' /etc/squid/squid.conf
else
  sed -i -E 's|^http_access allow (allowed_domains\|all)$|http_access allow allowed_domains|' /etc/squid/squid.conf
fi

# Clear any stale PID file left from a previous run
rm -f /var/run/squid.pid

# Initialize squid cache dirs if needed, then start the daemon
# (squid daemonizes itself; this returns immediately)
squid -z 2>/dev/null || true
rm -f /var/run/squid.pid  # -z may leave a stale PID file
squid

# Wait for squid to be ready on port 3128
for i in 1 2 3 4 5 6 7 8 9 10; do
  if nc -z localhost 3128 2>/dev/null; then
    echo "Squid is ready on localhost:3128"
    break
  fi
  sleep 0.5
done

if ! nc -z localhost 3128 2>/dev/null; then
  echo "ERROR: squid did not start on port 3128"
  cat /var/log/squid/cache.log 2>/dev/null | tail -20
  exit 1
fi

# If iptables is not available (no NET_ADMIN), skip the lockdown.
# Squid still runs, but enforcement relies on HTTPS_PROXY being respected.
if ! iptables -L -n &>/dev/null; then
  echo "Skipping iptables lockdown (NET_ADMIN capability not available)"
  echo "NOTE: proxy enforcement relies on HTTPS_PROXY env var"
  exit 0
fi

# Preserve Docker's internal DNS nat rules before flushing
DOCKER_DNS_RULES=$(iptables-save -t nat 2>/dev/null | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

if [ -n "$DOCKER_DNS_RULES" ]; then
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# Loopback is always allowed (agent ↔ squid runs over loopback)
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# DNS to all nameservers listed in /etc/resolv.conf (both UDP and TCP).
# Needed so squid can resolve upstream domains.
DNS_SERVERS=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}')
if [ -z "$DNS_SERVERS" ]; then
  echo "ERROR: No nameservers found in /etc/resolv.conf"
  exit 1
fi
for dns in $DNS_SERVERS; do
  echo "Allowing DNS to $dns"
  iptables -A OUTPUT -d "$dns" -p udp --dport 53 -j ACCEPT
  iptables -A INPUT -s "$dns" -p udp --sport 53 -j ACCEPT
  iptables -A OUTPUT -d "$dns" -p tcp --dport 53 -j ACCEPT
  iptables -A INPUT -s "$dns" -p tcp --sport 53 -j ACCEPT
done

# Allow the squid user (`proxy`) to make outbound TCP connections anywhere.
# Everyone else must go through squid via loopback, which will enforce the
# domain allowlist. This is how per-process isolation works here.
SQUID_UID=$(id -u proxy)
iptables -A OUTPUT -m owner --uid-owner "$SQUID_UID" -j ACCEPT

# Established / related return traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Default policies: drop everything else
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Block all IPv6
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true

echo "Firewall configuration complete"
echo "Verifying firewall rules..."

# Verify: example.com behavior depends on the mode
if [ "${ALLOW_ALL_DOMAINS:-}" = "1" ]; then
  if curl -x http://localhost:3128 --connect-timeout 10 -s -o /dev/null https://example.com; then
    echo "Firewall verification passed - example.com reachable via proxy (ALLOW_ALL_DOMAINS)"
  else
    echo "ERROR: ALLOW_ALL_DOMAINS mode but example.com unreachable via proxy"
    exit 1
  fi
else
  if curl -x http://localhost:3128 --connect-timeout 5 -s -o /dev/null https://example.com 2>/dev/null; then
    echo "ERROR: Firewall verification failed - example.com reachable via proxy"
    exit 1
  else
    echo "Firewall verification passed - example.com blocked as expected"
  fi
fi

# Verify: allowed domain through the proxy should work
if curl -x http://localhost:3128 --connect-timeout 10 -s -o /dev/null https://api.github.com/zen; then
  echo "Firewall verification passed - api.github.com reachable via proxy"
else
  echo "ERROR: Firewall verification failed - api.github.com unreachable via proxy"
  exit 1
fi

# Verify: direct connection (bypassing proxy) should fail
if curl --connect-timeout 5 -s -o /dev/null https://api.github.com 2>/dev/null; then
  echo "WARNING: direct HTTPS connection succeeded - proxy bypass may be possible"
else
  echo "Firewall verification passed - direct HTTPS blocked"
fi
