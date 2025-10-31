import jsonpickle
import enoslib as en
from enoslib.api import generate_inventory, run_ansible
from enoslib.infra.enos_vmong5k.configuration import Configuration
import time

en.set_config(ansible_forks=100)

# === Load saved reservation info ===
with open("reserved_management.json", "r") as f:
    roles = jsonpickle.decode(f.read())

with open("reserved_management_networks.json", "r") as f:
    networks = jsonpickle.decode(f.read())

# === VM deployment configuration ===
subnet = networks["my_subnet"]

cp = 1
w=1

print(list(subnet[0].free_macs)[1:2])

virt_conf = (
    #en.VMonG5kConf.from_settings(image="/grid5000/virt-images/debian11-x64-min-2025072511.qcow2")
    en.VMonG5kConf.from_settings(image="/home/chuang/images/arena-new-large.qcow2")
    .add_machine(
        roles=["cp"],
        number=cp,
        undercloud=roles["role0"],
        flavour_desc={"core": 4, "mem": 16384},
        macs=list(subnet[0].free_macs)[1:2],
    )
    .add_machine(
        roles=["member"],
        number=w,
        undercloud=roles["role0"],
        flavour_desc={"core": 4, "mem": 16384},
        macs=list(subnet[0].free_macs)[2:w+2],
    ).finalize()
)


# === Start VMs ===
vmroles = en.start_virtualmachines(virt_conf,force_deploy=True)

# === Generate Ansible inventory ===
inventory_file = "kubefed_inventory_redeploy.ini"
inventory = generate_inventory(vmroles, networks, inventory_file)

# === Wait for VMs to boot ===
for i in range(45, 0, -1):
    print(f"Remaining: {i} seconds")
    time.sleep(1)

# === Run post-deployment playbook ===
run_ansible(["afterbuild.yml"], inventory_path=inventory_file)

# === Save master node IP to file ===
master_node_ip = vmroles["cp"][0].address

with open("node_list", 'a') as f:
    f.write(str(master_node_ip))
    f.write("\n")

print("VM successfully deployed.")
print("Master node IP:", master_node_ip)