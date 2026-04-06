#!/bin/bash

set -euo pipefail

IFS=$'\n\t'

# Skip if iptables is not available (no NET_ADMIN capability)
if ! iptables -L -n &>/dev/null; then
  echo "Skipping firewall setup (NET_ADMIN capability not available)"
  exit 0
fi

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy github-ips 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# Allow DNS to all nameservers listed in /etc/resolv.conf
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
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipsets with CIDR support
ipset create allowed-domains hash:net
ipset create github-ips hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr"
    ipset add github-ips "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Resolve and add other allowed domains as /24 subnets for resilience against IP changes
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        cidr=$(echo "$ip" | sed 's/\.[0-9]*$/.0\/24/')
        echo "Adding $cidr for $domain (resolved: $ip)"
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done < <(echo "$ips")
done

# Add extra domains from ALLOWED_DOMAINS env var (comma-separated)
if [ -n "${ALLOWED_DOMAINS:-}" ]; then
    IFS=',' read -ra EXTRA_DOMAINS <<< "$ALLOWED_DOMAINS"
    for domain in "${EXTRA_DOMAINS[@]}"; do
        domain=$(echo "$domain" | xargs)  # trim whitespace
        [ -z "$domain" ] && continue
        echo "Resolving extra domain: $domain..."
        ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
        if [ -z "$ips" ]; then
            echo "WARNING: Failed to resolve extra domain $domain (skipping)"
            continue
        fi

        while read -r ip; do
            if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "WARNING: Invalid IP from DNS for $domain: $ip (skipping)"
                continue
            fi
            cidr=$(echo "$ip" | sed 's/\.[0-9]*$/.0\/24/')
            echo "Adding $cidr for $domain (resolved: $ip)"
            ipset add allowed-domains "$cidr" 2>/dev/null || true
        done < <(echo "$ips")
    done
fi

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Allow SSH only to GitHub IPs (for git+ssh)
iptables -A OUTPUT -p tcp --dport 22 -m set --match-set github-ips dst -j ACCEPT

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Allow established connections and whitelisted domains (HTTPS only) BEFORE setting DROP policy
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Now set default policies to DROP (all rules are already in place)
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Block all IPv6 traffic
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
