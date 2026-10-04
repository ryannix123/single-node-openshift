# Single Node OpenShift

**The complete guide to running OpenShift in your home lab, on a single machine.**

<img src="https://upload.wikimedia.org/wikipedia/commons/3/3a/OpenShift-LogoType.svg" alt="OpenShift Logo" width="200">

Many people have used this repo to get OpenShift running on everything from Intel NUCs to enterprise servers. Whether you're learning Kubernetes, building a home lab, or need a portable demo environment, Single Node OpenShift (SNO) is a great way to get started with enterprise-grade Kubernetes!

## Watch the Tutorials

These step-by-step video guides have helped nearly **15,000 viewers** get their SNO clusters up and running:

- [Single Node OpenShift Installation Walkthrough](https://youtu.be/leJa9HmvdI0) — Complete installation using the Assisted Installer
- [OpenShift Virtualization — Containers and VMs on the same control plane](https://youtu.be/ZV7KGqcPs7s) — Run containers and virtual machines side-by-side

---

## Prerequisites

Before running the day 2 playbook you'll need the following on your workstation:

- **Ansible** 2.14+: `pip install ansible`
- **Ansible collections**: `ansible-galaxy collection install kubernetes.core community.general`
- **`oc` CLI**: Download from [console.redhat.com](https://console.redhat.com/openshift/downloads) and add to your `$PATH`
- **kubeconfig**: Export your cluster's kubeconfig — `export KUBECONFIG=~/path/to/kubeconfig`
- **SSH key**: The private key you registered during Assisted Installer image creation. Defaults to `~/.ssh/id_rsa` — override with `-e ssh_key_path=~/.ssh/your_key` if different.

> **Identify your storage device first.** SSH into the SNO node and run `lsblk` to confirm which device is your secondary data disk. It is commonly `/dev/nvme1n1` or `/dev/sdb` but varies by hardware. Set `storage_device` in `vars/defaults.yml` accordingly before running the playbook.

---

## Known Issues

**Assisted Installer does not wipe secondary disks.** If you reinstall SNO on a machine that previously ran LVMS, the secondary disk will still have stale LVM partition table entries and device mapper state from the previous cluster. The day 2 playbook handles this automatically — it runs `dmsetup remove_all`, `partx -d`, and `sgdisk --zap-all` via SSH before creating the LVMCluster. If LVMS still reports `has children block devices and could not be considered` after a fresh install, SSH into the node and run:

```bash
sudo dmsetup remove_all -f
sudo partx -d /dev/nvme1n1   # use your data disk device
sudo sgdisk --zap-all /dev/nvme1n1
```

Then re-run the playbook. The playbook's wipe tasks are skipped if LVM children are already detected (idempotent on re-runs), so this is a safe operation.

**`oc debug` cannot wipe disks reliably.** The playbook uses SSH directly to the node for all disk operations. `oc debug` sessions hit kernel ioctl limitations (`BLKRRPART: Device or resource busy`) that make partition table reloads unreliable. SSH as the `core` user avoids this entirely.

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

## Automated TLS Certificates

Secure the SNO ingress domain — and the OpenShift web console served through it — with a free Let's Encrypt **wildcard** certificate that is obtained and **renewed automatically inside the cluster** by the cert-manager Operator for Red Hat OpenShift.

There's no certbot to run on your workstation and no quarterly renewal step. cert-manager solves the DNS-01 challenge through Cloudflare and rotates the certificate in place at ~day 60 of its 90-day lifetime. You point the ingress controller at the managed secret once, and it's hands-off from then on.

See the [cert-manager TLS Guide](docs/cert-manager/README.md) for the full walkthrough and manifests.

---

## Hardware Requirements

| Setup | CPU | RAM | Storage |
|-------|-----|-----|---------|
| Base cluster | 8 cores | 32 GB | 120 GB boot + data disk |
| With Virtualization | 8 cores | 32 GB | 120 GB + 100 GB |
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
  03-optional-operators.md  # Optional add-ons
  cert-manager/           # Automated Let's Encrypt wildcard TLS via cert-manager
    README.md             # TLS guide — start here
    00-operator-subscription.yaml
    01-cloudflare-secret.yaml
    02-clusterissuers.yaml
    03-wildcard-certificate.yaml

scripts/
  sno-shutdown.sh         # Clean shutdown + "how long can it stay off" report
  sno-csr-autoapprove.sh  # Boot-time kubelet CSR approval (homelab only)

manifests/
  99-master-sno-csr-autoapprove.yaml  # Installs the auto-approver — reboots the node
```

---

## Safe Shutdown

```bash
./scripts/sno-shutdown.sh
```

Approves any pending kubelet certificate requests, then tells you how long the
node can stay off: power on before the **no-touch restart** date and it rejoins
on its own. The dates are also saved to `~/.sno-last-shutdown` so you can check
them when you come back.

After that date, the kubelet returns asking for certificate approval. No
shutdown script can prevent that: kubelet certificates are capped at roughly
30 days by the cluster's signer, however recently they rotated.
(All of this is separate from the Let's Encrypt ingress certificate, which
cert-manager renews on its own.)

### Coming back after a long shutdown

If the node has been off past its no-touch date, approve its certificate
requests from the node itself:

```bash
ssh core@<node-ip>

# then, on the node:
K=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
sudo oc --kubeconfig=$K get csr --no-headers | awk '/Pending/ {print $1}' \
  | xargs -r sudo oc --kubeconfig=$K adm certificate approve
```

Run the approve line again after 30 seconds — a second request follows the
first. Expect the API to drop and return a few times over the next 10–20
minutes while operators roll out new certificates. Don't restart anything
while that happens.

### Making it automatic (homelab only)

```bash
oc apply -f manifests/99-master-sno-csr-autoapprove.yaml
```

Installs a boot-time service that does the approval above for you, for this
node's own kubelet requests only. **Applying it reboots the node.** Do not use
it on multi-node or production clusters — OpenShift refuses to auto-approve
these requests by design, because it cannot prove a returning node's identity.

---

## Tested With

- OpenShift 4.15 – 4.21

---

## Contributing

Found a bug? Have a better way to do something? PRs and issues are welcome.

---

## About

Created by Ryan Nix. This is a personal project to help the OpenShift community — not an official Red Hat resource.

If this repo helped you, consider giving it a ⭐. It helps others find it too.
