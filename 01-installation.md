# Installation Guide

This guide walks you through deploying Single Node OpenShift using Red Hat's **Assisted Installer** — the easiest, most reliable way to get SNO running on physical or virtual hardware.

**Total time:** ~45 minutes (most of which is unattended)

---

## Prerequisites

Before you start, make sure you have:

- A Red Hat account (free at [console.redhat.com](https://console.redhat.com))
- A machine meeting the [hardware requirements](../README.md#hardware-requirements)
- A secondary block device (separate from the OS drive) for LVM storage
- A static IP address or DHCP reservation for the node
- A DNS entry pointing your cluster's API and wildcard ingress at the node IP:
  ```
  api.<cluster-name>.<base-domain>      → <node-ip>
  *.apps.<cluster-name>.<base-domain>   → <node-ip>
  ```

---

## Step 1 — Create a Cluster in the Assisted Installer

1. Go to [console.redhat.com/openshift/assisted-installer/clusters](https://console.redhat.com/openshift/assisted-installer/clusters)
2. Click **Create cluster**
3. Fill in:
   - **Cluster name** — e.g. `sno`
   - **Base domain** — e.g. `example.com`
   - **OpenShift version** — choose the latest 4.x release
   - **CPU architecture** — match your hardware (x86\_64 or arm64)
4. Check **Install single node OpenShift (SNO)**
5. Click **Next**

---

## Step 2 — Generate and Boot the Discovery ISO

1. On the **Host discovery** screen, click **Generate Discovery ISO**
2. Optionally add your SSH public key so you can SSH into the node post-install
3. Download the ISO
4. Boot your target machine from the ISO (USB drive, iDRAC, iLO, PXE, etc.)
5. The node will appear in the Assisted Installer UI within a few minutes

---

## Step 3 — Configure Storage and Networking

Once the node appears:

1. Verify the **hostname** and **IP address** look correct
2. Under **Storage**, confirm the Assisted Installer has detected both your boot drive and your secondary data drive
3. If your data drive isn't recognized, check the [LVM drive fix note](#lvm-drive-not-recognized) below

---

## Step 4 — Install

1. Click **Next** through the validation screens
2. Review the summary and click **Install cluster**
3. Watch the progress bar — the install takes 30–40 minutes
4. When complete, download your `kubeconfig` from the **Credentials** section

---

## Step 5 — Verify Access

```bash
export KUBECONFIG=~/Downloads/kubeconfig

# Cluster operators should all be Available
oc get co

# You should see your single node
oc get nodes
```

If all cluster operators are green, you're ready for [Day 2 operations](../README.md#step-2--run-the-day-2-playbook).

---

## LVM Drive Not Recognized

If your secondary drive doesn't appear during installation, it may have leftover partition data. Boot a live Linux environment and run:

```bash
# Replace /dev/sdb with your device
sudo sgdisk --zap-all /dev/sdb
sudo wipefs -a /dev/sdb
sudo partprobe /dev/sdb
```

Then re-register the host in the Assisted Installer. The Day 2 playbook also handles this automatically for you.

---

## Next Step

➡️ [Run the Day 2 playbook](../README.md#step-2--run-the-day-2-playbook)
