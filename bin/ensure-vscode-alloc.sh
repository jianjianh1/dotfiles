#!/bin/bash
# ensure-vscode-alloc.sh — idempotently guarantee a long-lived "sleep
# infinity" allocation named $VSCODE_SSH_NAME (default: vscode-ssh) for the
# current user, then print the assigned compute node on stdout.
#
# Designed to be called from an SSH ProxyCommand on the user's laptop:
#   ssh login.host "$HOME/.server-configs/bin/ensure-vscode-alloc.sh"
# Stdout must be a clean hostname; logs go to stderr.
#
# Env overrides (parallel to vscode-ssh-alloc in bashrc_aliases):
#   VSCODE_SSH_NAME       job name (default: vscode-ssh)
#   VSCODE_SSH_ACCOUNT    sbatch -A (default: notchpeak-shared-short)
#   VSCODE_SSH_PARTITION  sbatch -p (default: notchpeak-shared-short)
#   VSCODE_SSH_QOS        sbatch -q (default: notchpeak-shared-short)
#   VSCODE_SSH_CORES      sbatch -n (default: 8)
#   VSCODE_SSH_MEM        sbatch --mem (default: 32G)
#   VSCODE_SSH_TIME       sbatch -t  (default: 8:00:00)

set -uo pipefail

log() { printf '[ensure-vscode-alloc] %s\n' "$*" >&2; }
die() { log "$@"; exit 1; }

command -v squeue >/dev/null 2>&1 || die "squeue not found — not a SLURM host"
command -v sbatch >/dev/null 2>&1 || die "sbatch not found — not a SLURM host"

name="${VSCODE_SSH_NAME:-vscode-ssh}"
acct="${VSCODE_SSH_ACCOUNT:-notchpeak-shared-short}"
part="${VSCODE_SSH_PARTITION:-notchpeak-shared-short}"
qos="${VSCODE_SSH_QOS:-notchpeak-shared-short}"
cores="${VSCODE_SSH_CORES:-8}"
mem="${VSCODE_SSH_MEM:-32G}"
time="${VSCODE_SSH_TIME:-8:00:00}"

# Reuse an existing running job if one is already allocated.
existing="$(squeue -h -u "$USER" -n "$name" -t RUNNING -o '%N' 2>/dev/null | head -n1)"
case "$existing" in
    ""|"(null)"|n/a) ;;
    *)
        printf '%s\n' "$existing"
        exit 0
        ;;
esac

# Reuse a pending job (don't double-submit) — we'll wait on it below.
jobid="$(squeue -h -u "$USER" -n "$name" -o '%i' 2>/dev/null | head -n1)"
if [ -z "$jobid" ]; then
    log "submitting new allocation: $cores cores, $mem, $time on $part"
    jobid="$(sbatch --parsable -A "$acct" -p "$part" -q "$qos" \
                    -n "$cores" --mem="$mem" -t "$time" -J "$name" \
                    --wrap='sleep infinity' 2>/dev/null)" || die "sbatch failed"
    [ -n "$jobid" ] || die "sbatch returned empty jobid"
    log "submitted job $jobid; waiting for node assignment"
else
    log "reusing pending job $jobid; waiting for node assignment"
fi

tries=0
node=""
while [ "$tries" -lt 120 ]; do
    node="$(squeue -h -j "$jobid" -o '%N' 2>/dev/null)"
    case "$node" in
        ""|"(null)"|n/a) ;;
        *) break ;;
    esac
    sleep 2
    tries=$((tries + 1))
done

if [ -z "$node" ] || [ "$node" = "(null)" ]; then
    die "timed out waiting for job $jobid; check 'squeue --me' or scancel $jobid"
fi

printf '%s\n' "$node"
