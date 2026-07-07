#!/bin/bash
set -e

# ───────────────────────────────────────────────────────────────
# Arena Testbed — environment bootstrap (multi-host kind)
# ───────────────────────────────────────────────────────────────
# Installs docker, helm, kubectl, Go, then builds the Arena-flavoured
# kind fork (Clement-NI/kind_extension_for_arena) from source. SSH key
# propagation and docker context creation for remote hosts are handled
# by the fork's scripts/setup-multihost.sh — run that script from this
# (the manager) host once nodes.json has been edited.
# ───────────────────────────────────────────────────────────────

log_info()  { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

KIND_FORK_REPO="${KIND_FORK_REPO:-https://github.com/Clement-NI/kind_extension_for_arena.git}"
KIND_FORK_REF="${KIND_FORK_REF:-main}"
KIND_SRC_DIR="${KIND_SRC_DIR:-/opt/kind_extension_for_arena}"
GO_VERSION="${GO_VERSION:-1.25.7}"

# ───────────────────────────────────────────────────────────────
# Base packages + docker
# ───────────────────────────────────────────────────────────────

apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl sudo python3-pip python3 vim wget git net-tools jq
echo 'set mouse=' >> ~/.vimrc
swapoff -a
pip3 install requests pyyaml
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update

VERSION_STRING=5:28.0.4-1~debian.11~bullseye
apt-get install -y docker-ce=$VERSION_STRING docker-ce-cli=$VERSION_STRING containerd.io docker-buildx-plugin docker-compose-plugin

wget https://get.helm.sh/helm-v3.17.4-linux-amd64.tar.gz
tar -zxvf helm-v3.17.4-linux-amd64.tar.gz
mv linux-amd64/helm /usr/local/bin/helm
rm -rf linux-amd64/
rm -f helm-v3.17.4-linux-amd64.tar.gz

sudo bash -c 'cat > /etc/docker/daemon.json <<EOF
{
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Soft": 1048576,
      "Hard": 1048576
    }
  }
}
EOF'

sudo systemctl daemon-reload
sudo systemctl restart docker

echo 'fs.inotify.max_user_instances=2048' | sudo tee /etc/sysctl.d/99-inotify-instances.conf
sudo sysctl --system

# ───────────────────────────────────────────────────────────────
# kubectl
# ───────────────────────────────────────────────────────────────

OS=$(uname -s)
ARCH=$(uname -m)
ARCH_DL=$ARCH
if [[ "$ARCH" == "x86_64" ]]; then
  ARCH_DL="amd64"
elif [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
  ARCH_DL="arm64"
else
  log_error "Unsupported architecture: $ARCH"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  log_info "Installing kubectl..."
  if [[ "$OS" == "Darwin" ]]; then
    curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/darwin/${ARCH_DL}/kubectl"
  else
    curl -LO "https://dl.k8s.io/release/v1.33.2/bin/linux/${ARCH_DL}/kubectl"
  fi
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/kubectl
  log_info "kubectl installed."
else
  log_info "kubectl already present."
fi

# ───────────────────────────────────────────────────────────────
# Go (to build the kind fork)
# ───────────────────────────────────────────────────────────────

need_go=1
if command -v go >/dev/null 2>&1; then
  current_go=$(go version | awk '{print $3}' | sed 's/^go//')
  if [[ "$(printf '%s\n%s\n' "$GO_VERSION" "$current_go" | sort -V | head -1)" == "$GO_VERSION" ]]; then
    log_info "Go already installed: $current_go (>= $GO_VERSION)"
    need_go=0
  fi
fi
if [[ "$need_go" == "1" ]]; then
  log_info "Installing Go ${GO_VERSION}..."
  GO_TARBALL="go${GO_VERSION}.linux-${ARCH_DL}.tar.gz"
  curl -fsSL "https://go.dev/dl/${GO_TARBALL}" -o "/tmp/${GO_TARBALL}"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "/tmp/${GO_TARBALL}"
  rm -f "/tmp/${GO_TARBALL}"
  export PATH=/usr/local/go/bin:$PATH
  if ! grep -q '/usr/local/go/bin' /etc/profile.d/golang.sh 2>/dev/null; then
    echo 'export PATH=/usr/local/go/bin:$PATH' | sudo tee /etc/profile.d/golang.sh >/dev/null
    sudo chmod +x /etc/profile.d/golang.sh
  fi
  log_info "Go installed: $(go version)"
fi

# ───────────────────────────────────────────────────────────────
# Build kind from the Arena fork
# ───────────────────────────────────────────────────────────────

log_info "Fetching kind fork ${KIND_FORK_REPO}@${KIND_FORK_REF}..."
if [[ -d "$KIND_SRC_DIR/.git" ]]; then
  git -C "$KIND_SRC_DIR" fetch origin
  git -C "$KIND_SRC_DIR" checkout "$KIND_FORK_REF"
  git -C "$KIND_SRC_DIR" pull --ff-only origin "$KIND_FORK_REF" || true
else
  sudo mkdir -p "$(dirname "$KIND_SRC_DIR")"
  sudo git clone "$KIND_FORK_REPO" "$KIND_SRC_DIR"
  git -C "$KIND_SRC_DIR" checkout "$KIND_FORK_REF"
fi

log_info "Building kind binary..."
( cd "$KIND_SRC_DIR" && /usr/local/go/bin/go build -o /tmp/kind ./ )
sudo install -m 0755 /tmp/kind /usr/local/bin/kind
rm -f /tmp/kind

if ! kind --help 2>&1 | grep -q -- '--multihost'; then
  log_error "Built kind binary is missing --multihost flag — check the fork"
fi
log_info "kind installed: $(kind --version)"

# ───────────────────────────────────────────────────────────────
# Remote host bootstrap (only when nodes.json has > 1 host)
# ───────────────────────────────────────────────────────────────

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
NODES_JSON="${SCRIPT_DIR}/nodes.json"

if [[ -f "$NODES_JSON" ]]; then
  REMOTE_CTXS=$(jq -r '[.hosts[] | select(.context != "default" and (.ssh // "") != "") | .ssh | capture("ssh://(?<u>[^@]+)@(?<h>.+)").h] | join(" ")' "$NODES_JSON")
  if [[ -n "$REMOTE_CTXS" ]]; then
    log_warn "nodes.json declares remote hosts: $REMOTE_CTXS"
    log_warn "Bootstrap their SSH keys + docker contexts by running, from this machine:"
    log_warn "    bash ${KIND_SRC_DIR}/scripts/setup-multihost.sh $REMOTE_CTXS"
    log_warn "(see the fork's README for prerequisites — root@<host> SSH access)"
  fi
fi

log_info "Environment ready. Run ./1-launch_cluster.sh next."