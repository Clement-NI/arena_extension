## reserve the hosts from Grid'5000
ssh nantes
oarsub -I -p ecotype -l host=3,walltime=3:00:00 -t deploy
kadeploy3 debian11-min --env-version 2025072511
## Install the environnement(wget,curl,docker...)
apt-get update
apt-get upgrade -y
apt-get install -y vim wget git net-tools jq
apt-get install -y docker.io
systemctl enable --now docker
echo 'set mouse=' >> ~/.vimrc
swapoff -a
apt install -y curl
curl -fsSL https://ollama.com/install.sh | sh
##To launch the Ai agent, you have to download ollama to get some cheap and light LLM (for free)

## Python 3.13 + venv + dependence
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.local/bin/env        
uv python install 3.13
cd /root/arena_extension
uv venv --python 3.13
source .venv/bin/activate
uv pip install -r ai_agent/requirements.txt
python -m ensurepip --upgrade

### If necessary, move the cach of docker to a larger disk 
systemctl stop docker.socket
systemctl stop docker
sleep 3
mv /var/lib/docker /tmp/docker-data
ln -s /tmp/docker-data /var/lib/docker
systemctl start docker
sleep 5


## Install arena

git clone https://github.com/Clement-NI/arena_extension.git
cd arena_extension
chmod -R +x .
docker context ls 
cd arena_testbed/
./0b-setup-multihost.sh (<host 1>, <host 2>) ##If multi-host. Then follow the instructions by script


## lauch the cluster without CNI
./1-launch_cluster.sh

## Install Cilium, Chaosmesh and Promethus
./2-set_frameworks.sh


## Clean the cluster
./3-clean_cluster.sh (<HOST 1>,<HOST 2>...)



## In other machines (for a cluster with large scale)
sysctl -w fs.inotify.max_user_instances=8192
sysctl -w fs.inotify.max_user_watches=1048576
sysctl -w kernel.keys.maxkeys=20000


mkdir -p /tmp/docker-data
cat > /etc/docker/daemon.json <<'EOF'
{
  "data-root": "/tmp/docker-data",
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 1048576, "Hard": 1048576 }
  }
}
EOF
systemctl restart docker


docker info | grep "Docker Root Dir"          
sysctl fs.inotify.max_user_instances          


## Launch the Ai agent with langgraph dev

### You can lauch the ai agent with just the docker context of multi hosts (or you don't have to get it when you are in the "single host" mode)

### Make sure that the LLMs are disponible here. If it's not the case, fill in `.env` your API keys for the LLM.
langgraph dev.

## Usage of AI Agent 
You can read `ai_agent/README.md` to get more informations on the usage of Ai agent.