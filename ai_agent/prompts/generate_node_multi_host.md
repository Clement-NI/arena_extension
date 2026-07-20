I want a cluster with 10 nodes on multi hosts: 4 IoT nodes, 3 Edge nodes
and 3 Cloud nodes, one of the Cloud nodes is the control plane.

The nodes should be distributed in 3 hosts (default is ecotype-45, the others are ecotype-7 and ecotype-46)
The base IP for these hosts is 172.16.193.x where x is the number of the host.(For ecotype-6 it's 172.16.193.6).

Network between tiers:
iot <-> edge: 10ms latency, 50Mbit bandwidth, 1% loss
edge <-> cloud: 30ms latency, 200Mbit bandwidth
iot <-> cloud: 50ms latency, 20Mbit bandwidth, 5% loss
inside each tier: 1ms latency, 400Mbit bandwidth

Launch the cluster, then apply the chaos rules with kubectl.
