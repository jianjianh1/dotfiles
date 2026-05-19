#!/bin/bash
# vscode-compute-ssh-proxy.sh — SSH ProxyCommand that routes a connection
# through a CHPC login host onto an auto-allocated compute node. The flow is:
#
#   1. ssh into the login host (one connection), run ensure-vscode-alloc.sh
#      to get a "vscode-ssh" compute node name (creating the alloc if needed)
#   2. exec `ssh -W <node>:22 <login>` so the outer ssh client tunnels stdin/
#      stdout straight to the compute node's sshd via the login host
#
# Configured from ~/.server-configs-generated/sshconfig.compute (rendered by
# setup.sh on every host that runs it):
#   Host notchpeak-compute
#       ProxyCommand /path/to/this/script <login-host> <remote-user>
#
# Args:
#   $1 = login host (default: notchpeak.chpc.utah.edu)
#   $2 = remote username (default: $USER on the local machine)
#
# Notes:
# - This script runs on the *laptop* side of the SSH connection. It only
#   needs `ssh` available locally.
# - ControlMaster sockets in the universal sshconfig pool both legs, so the
#   alloc-probe leg and the -W leg often share a TCP connection.

set -uo pipefail

login="${1:-notchpeak.chpc.utah.edu}"
remote_user="${2:-$USER}"

log() { printf '[vscode-compute-ssh-proxy] %s\n' "$*" >&2; }

# Allow callers to point at a non-standard install path (e.g., during
# bootstrap before ~/.server-configs is cloned).
remote_helper="${VSCODE_COMPUTE_ALLOC_HELPER:-\$HOME/.server-configs/bin/ensure-vscode-alloc.sh}"

node="$(ssh -o BatchMode=yes -o LogLevel=ERROR "${remote_user}@${login}" \
        "bash -lc '${remote_helper}'" 2>&1)" || {
    log "failed to query compute node via ${login}: $node"
    exit 1
}

node="$(printf '%s' "$node" | tr -d '[:space:]')"
case "$node" in
    ""|*[!a-zA-Z0-9._-]*)
        log "unexpected response from helper: $node"
        exit 1
        ;;
esac

log "routing to compute node ${node} via ${login}"
exec ssh -W "${node}:22" "${remote_user}@${login}"
