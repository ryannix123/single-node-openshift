# Single Node OpenShift

**The complete guide to running OpenShift in your home lab, on a single machine.**

<img src="https://upload.wikimedia.org/wikipedia/commons/3/3a/OpenShift-LogoType.svg" alt="OpenShift Logo" width="200">

Many people have used this repo to get OpenShift running on everything from Intel NUCs to enterprise servers. Whether you're learning Kubernetes, building a home lab, or need a portable demo environment, Single Node OpenShift (SNO) is a great way to get started with enterprise-grade Kubernetes!

## Watch the Tutorials

These step-by-step video guides have helped nearly **15,000 viewers** get their SNO clusters up and running:

- [Single Node OpenShift Installation Walkthrough](https://youtu.be/leJa9HmvdI0) — Complete installation using the Assisted Installer
- [OpenShift Virtualization — Containers and VMs on the same control plane](https://youtu.be/ZV7KGqcPs7s) — Run containers and virtual machines side-by-side

---

## Two Steps to a Full SNO Cluster

### Step 1 — Install OpenShift

Follow the [Installation Guide](docs/01-installation.md) to deploy SNO using Red Hat's Assisted Installer. The process takes about 45 minutes and produces a fully functional cluster.

### Step 2 — Run the Day 2 Playbook

Everything after installation is automated by a single Ansible playbook:

```bash
# Install the required Ansible collections
ansible-galaxy collection install kubernetes.core community.general

# Clone the repo
git clone https://github.com/ryannix123/single-node-openshift.git
cd single-node-openshift

# Run the day 2 playbook
ansible-playbook sno-day2.yml
```

The playbook will:

- Wipe and prepare your secondary drive for LVM storage
- Install the LVM Storage Operator and create an LVMCluster
- Set `lvms-vg1` as the default StorageClass
- Patch the image registry to use persistent storage
- Patch cluster monitoring (Prometheus) to use persistent storage
- Install OpenShift Virtualization and activate the HyperConverged instance

Each step has readiness gates — it won't proceed until the previous phase is healthy.

#### Customizing the playbook

Override any variable on the command line or create a vars file:

```bash
# Common overrides
ansible-playbook sno-day2.yml \
  -e kubeconfig=/path/to/kubeconfig \
  -e storage_device=/dev/nvme1n1 \
  -e registry_size=200Gi \
  -e monitoring_size=80Gi
```

See [`vars/defaults.yml`](vars/defaults.yml) for all available variables and their defaults.

---

## Optional Add-ons

After the day 2 playbook completes, you can layer in additional capabilities using the pre-built manifests:

| Add-on | Manifests | Notes |
|--------|-----------|-------|
| Ansible Automation Platform | `manifests/operators/aap/` | Requires 12+ cores, 48GB RAM |
| Advanced Cluster Management | `manifests/operators/acm/` | Requires 16+ cores, 64GB RAM |
| Let's Encrypt TLS certs | `manifests/tls/` | See [TLS Guide](docs/02-tls.md) |

---

## Hardware Requirements

| Setup | CPU | RAM | Storage |
|-------|-----|-----|---------|
| Base cluster | 8 cores | 32 GB | 120 GB boot + data disk |
| With Virtualization | 8 cores | 32 GB | 120 GB + 100 GB |
| With AAP | 12 cores | 48 GB | 120 GB + 100 GB |
| With ACM | 16 cores | 64 GB | 120 GB + 200 GB |
| Full stack | 16+ cores | 64 GB+ | 120 GB + 500 GB |

An NVMe drive for your data disk makes a noticeable difference in performance.

---

## Repository Layout

```
sno-day2.yml              # Day 2 operations playbook — start here
vars/
  defaults.yml            # All tunable variables with documentation

docs/
  01-installation.md      # Getting SNO installed via Assisted Installer
  02-tls.md               # Free Let's Encrypt certificates
  03-optional-operators.md  # AAP, ACM, and other add-ons

manifests/
  operators/
    aap/                  # Ansible Automation Platform 2.6
    acm/                  # Advanced Cluster Management
  tls/                    # Let's Encrypt configuration

scripts/
  sno-shutdown.sh         # Safe shutdown with certificate rotation
  renew-letsencrypt.sh    # Certificate renewal
```

---

## Safe Shutdown

SNO clusters that sit idle can develop certificate problems. Always shut down using the included script:

```bash
./scripts/sno-shutdown.sh
```

It handles certificate rotation automatically before the node powers off.

---

## Tested With

- OpenShift 4.15 – 4.21
- Ansible Automation Platform 2.5, 2.6
- Advanced Cluster Management 2.10, 2.11, 2.12

---

## Contributing

Found a bug? Have a better way to do something? PRs and issues are welcome.

---

## About

Created by Ryan Nix. This is a personal project to help the OpenShift community — not an official Red Hat resource.

If this repo helped you, consider giving it a ⭐. It helps others find it too.
