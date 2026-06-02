#!/usr/bin/env python3
"""
Traducteur topology.yaml → K8s + ChaosMesh YAML
Usage : python generator.py topology.yaml network_profiles.yaml
"""
import sys
import yaml
from pathlib import Path
from jinja2 import Environment, FileSystemLoader

SCRIPT_DIR = Path(__file__).parent
TEMPLATES_DIR = SCRIPT_DIR / "templates"
OUTPUT_DIR = SCRIPT_DIR / "output"


def load_yaml(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def render(env: Environment, template_name: str, **vars) -> str:
    template = env.get_template(template_name)
    return template.render(**vars)


def generate(topology: dict, profiles: dict) -> tuple[str, str]:
    """
    Retourne (deployments_yaml, chaos_yaml).
    """
    env = Environment(
        loader=FileSystemLoader(TEMPLATES_DIR),
        trim_blocks=True,
        lstrip_blocks=True,
    )

    deployments = []
    chaos = []

    # 1) Pour chaque nœud : Deployment + Service
    for node in topology["nodes"]:
        deployments.append(render(env, "deployment.yaml.j2", **node))
        deployments.append(render(env, "service.yaml.j2", **node))

    # 2) Pour chaque lien : générer les règles NetworkChaos
    for link in topology.get("links", []):
        profile = profiles.get(link["network"])
        if profile is None:
            raise ValueError(f"Profil réseau inconnu : {link['network']}")

        base = {"from_app": link["from"], "to_app": link["to"]}

        if "latency" in profile:
            chaos.append(render(
                env, "chaos_delay.yaml.j2",
                latency=profile["latency"],
                jitter=profile.get("jitter", "0ms"),
                **base,
            ))

        if "bandwidth" in profile:
            chaos.append(render(
                env, "chaos_bandwidth.yaml.j2",
                rate=profile["bandwidth"],
                **base,
            ))

        if "loss" in profile and profile["loss"] not in ("0%", "0", 0):
            loss_pct = str(profile["loss"]).rstrip("%")
            chaos.append(render(
                env, "chaos_loss.yaml.j2",
                loss_pct=loss_pct,
                **base,
            ))

    sep = "\n---\n"
    return sep.join(d.strip() for d in deployments), sep.join(c.strip() for c in chaos)


def main():
    if len(sys.argv) != 3:
        print("Usage: python generator.py <topology.yaml> <network_profiles.yaml>")
        sys.exit(1)

    topology = load_yaml(sys.argv[1])
    profiles = load_yaml(sys.argv[2])

    deployments_yaml, chaos_yaml = generate(topology, profiles)

    OUTPUT_DIR.mkdir(exist_ok=True)
    (OUTPUT_DIR / "deployments.yaml").write_text(deployments_yaml)
    (OUTPUT_DIR / "network-chaos.yaml").write_text(chaos_yaml)

    print(f"✅ Generated {len(topology['nodes'])} nodes, "
          f"{len(topology.get('links', []))} links")
    print(f"   → {OUTPUT_DIR}/deployments.yaml")
    print(f"   → {OUTPUT_DIR}/network-chaos.yaml")


if __name__ == "__main__":
    main()
