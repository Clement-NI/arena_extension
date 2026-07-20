#!/usr/bin/env bash
# clean-multihost.sh — tear down the multi-host Arena kind cluster cleanly.
#
# Deletes the kind cluster, force-removes any leftover node containers on the
# manager (default context) AND every worker host, leaves the Swarm and prunes
# leftover networks everywhere, then reports remaining containers per host.
#
# Worker hosts are passed as args; each must be a docker context name on this
# manager that is also SSH-reachable as root@<name> (as created by the fork's
# setup-multihost.sh).
#
# Usage:
#   ./clean-multihost.sh <worker1> [<worker2> ...]
#
# Examples:
#   ./clean-multihost.sh ecotype-35 ecotype-43
#   ./clean-multihost.sh                # manager-only cleanup (no workers)
#
# Cluster name defaults to the one in nodes.json (or "arena-testbed").

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CLUSTER="${CLUSTER:-$(jq -r '.cluster_name // "arena-testbed"' "$SCRIPT_DIR/nodes.json" 2>/dev/null || echo arena-testbed)}"

WORKERS=("$@")
CONTEXTS=(default "${WORKERS[@]}")

echo "==== cleaning cluster '$CLUSTER' across: ${CONTEXTS[*]} ===="

# 1. delete the kind cluster (best effort)
kind delete cluster --name "$CLUSTER" 2>/dev/null || true

# 2. force-remove any leftover node containers on every host
for ctx in "${CONTEXTS[@]}"; do
  ids=$(docker --context "$ctx" ps -aq --filter "label=io.x-k8s.kind.cluster=$CLUSTER" 2>/dev/null)
  if [ -n "$ids" ]; then
    echo "[$ctx] removing $(echo "$ids" | wc -w) container(s)"
    docker --context "$ctx" rm -f $ids >/dev/null 2>&1 || true
  fi
done

# 3. leave the Swarm + prune leftover networks everywhere
#    manager (local) first, then each worker over SSH
docker swarm leave --force >/dev/null 2>&1 || true
docker network prune -f    >/dev/null 2>&1 || true
for h in "${WORKERS[@]}"; do
  ssh root@"$h" 'docker swarm leave --force >/dev/null 2>&1; docker network prune -f >/dev/null 2>&1' || \
    echo "[WARN] ssh root@$h cleanup failed (host unreachable?)"
done

# 4. report remaining cluster containers per host (should all be 0)
echo "---- leftover check ----"
allzero=1
for ctx in "${CONTEXTS[@]}"; do
  n=$(docker --context "$ctx" ps -aq --filter "label=io.x-k8s.kind.cluster=$CLUSTER" 2>/dev/null | wc -l)
  printf "  [%s] leftover: %s\n" "$ctx" "$n"
  [ "$n" -ne 0 ] && allzero=0
done

if [ "$allzero" -eq 1 ]; then
  echo "==== clean: no leftover containers ===="
else
  echo "==== WARNING: some hosts still have containers (see above) ===="
fi
