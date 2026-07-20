#!/usr/bin/env bash
# setup-multihost.sh — does steps 2 and 3 of the checklist:
#   - ed25519 SSH key on the manager (generated if missing)
#   - propagates the public key to each worker (via ssh, will ask for the
#     password once per worker if password-based SSH is enabled)
#   - adds the workers' host keys to the manager's known_hosts
#   - creates the docker context for each worker
#   - checks that each daemon responds
#
# Run FROM the manager (e.g. ecotype-5).
#
# Usage:
#   ./setup-multihost.sh <worker1> [<worker2> ...]
# Example:
#   ./setup-multihost.sh ecotype-6 ecotype-47

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <worker1> [<worker2> ...]" >&2
    exit 2
fi
WORKERS=("$@")

step() { echo; echo "════════ $* ════════"; }

# ─── 1. SSH key ──────────────────────────────────────────────────────
step "1. local SSH key"
if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
fi
PUB=$(cat ~/.ssh/id_ed25519.pub)
echo "public key: ${PUB:0:60}..."

# ─── 2. propagate the key + fetch the host key ───────────────────────
step "2. propagating the key to ${#WORKERS[@]} worker(s)"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/known_hosts && chmod 600 ~/.ssh/known_hosts

NEEDS_MANUAL=()

for w in "${WORKERS[@]}"; do
    echo
    echo "── $w ──"
    # known_hosts (avoids "Host key verification failed" on later commands)
    ssh-keyscan -H "$w" >> ~/.ssh/known_hosts 2>/dev/null || true

    if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$w" true 2>/dev/null; then
        echo "$w: key already installed ✓"
        continue
    fi

    # try to install via ssh-copy-id (interactive password)
    if command -v ssh-copy-id >/dev/null && \
       ssh-copy-id -o StrictHostKeyChecking=accept-new "root@$w" 2>/dev/null; then
        echo "$w: key installed via ssh-copy-id ✓"
        continue
    fi

    echo "$w: automatic install impossible (password-based SSH disabled on the worker)"
    NEEDS_MANUAL+=("$w")
done

# If some workers require a manual install, print ONCE at the end of the
# section a ready-to-paste block for each affected worker, then stop.
if [ "${#NEEDS_MANUAL[@]}" -gt 0 ]; then
    cat >&2 <<EOF

════════ MANUAL ACTION REQUIRED ════════

Connect to each of the workers below (from your Grid'5000 frontend,
not from this manager) and run EXACTLY this block:

    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    echo '$PUB' >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys

Affected workers:
EOF
    for w in "${NEEDS_MANUAL[@]}"; do
        echo "    ssh root@$w" >&2
    done
    cat >&2 <<EOF

Then re-run:
    $0 ${WORKERS[*]}

EOF
    exit 1
fi

# ─── 3. check passwordless ───────────────────────────────────────────
step "3. passwordless check"
for w in "${WORKERS[@]}"; do
    ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$w" echo "$w OK"
done

# ─── 4. docker contexts ──────────────────────────────────────────────
step "4. docker contexts"
for w in "${WORKERS[@]}"; do
    if docker context inspect "$w" >/dev/null 2>&1; then
        echo "$w: context already created ✓"
    else
        docker context create "$w" --docker host="ssh://root@$w"
    fi
done

# ─── 5. check remote daemons ─────────────────────────────────────────
step "5. do all daemons respond?"
for w in default "${WORKERS[@]}"; do
    if v=$(docker --context "$w" version --format '{{.Server.Version}}' 2>/dev/null); then
        echo "$w: docker $v ✓"
    else
        echo "$w: FAIL — the daemon does not respond" >&2
        exit 1
    fi
done

step "READY — you can now run the arena plus in multi host mode"
