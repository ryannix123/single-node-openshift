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

If your secondary drive doesn't appear during installation — or the Assisted Installer flags it because it still carries partitions, a filesystem, or an old LVM volume group from a previous build — you have two ways to clear it. **Prefer Option A:** let the operator do the wipe so nobody has to touch a Live ISO or run manual disk commands.

### Option A (Recommended) — Let the operator wipe the disk

The LVM Storage operator can wipe the device for you when it creates the volume group. Add `forceWipeDevicesAndDestroyAllData: true` to the `deviceSelector` in your `LVMCluster` CR. This is declarative and repeatable — the operator removes any leftover partition table, filesystem, and LVM metadata before building the volume group, so a "dirty" disk is handled as part of normal provisioning.

```yaml
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
      - name: vg1
        default: true
        deviceSelector:
          # Use a STABLE path — kernel names like /dev/nvme0n1 can reorder across reboots
          paths:
            - /dev/disk/by-id/nvme-<your-disk-id>
          forceWipeDevicesAndDestroyAllData: true   # ⚠️ destroys ALL data on the listed device(s)
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
```

> ⚠️ **This permanently destroys everything on the listed device.** It irreversibly removes partition tables, filesystems, and existing LVM metadata before creating the volume group. Verify the device path more than once. Using `/dev/disk/by-id/` instead of `/dev/nvme0n1` protects you from the kernel renaming disks across reboots — list your stable paths with:
>
> ```bash
> ls -l /dev/disk/by-id/
> ```

### Option B — Wipe before install from a Live ISO

If you'd rather clean the disk ahead of time, boot a live Linux environment and run:

```bash
# Replace /dev/sdb with your device
sudo sgdisk --zap-all /dev/sdb
sudo wipefs -a /dev/sdb
sudo partprobe /dev/sdb
```

Then re-register the host in the Assisted Installer. The Day 2 playbook also handles this automatically for you.

---

## Reclaiming a Secondary Drive After Installation

**You forgot to wipe the drive before installing — now what?** You do **not** need to reinstall. The disk can be reclaimed live.

**Symptom.** An old volume group (e.g. `vg1` with a thin pool and leftover logical volumes from a previous build) is still on the secondary drive, and attempts to wipe it fail:

```
wipefs: error: /dev/nvme0n1: probing initialization failed: Device or resource busy
```

**Why it happens.** RHCOS auto-activates any volume group it finds at boot. Those active LVM device-mapper mappings hold the disk open, so `wipefs` can't get exclusive access. `sgdisk --zap-all` only rewrites the *in-memory* GPT — it doesn't release the mappings, which is why the "GPT destroyed" message is misleading and the disk stays busy.

### Preferred: fix it through the operator

If the LVM Storage operator will own this disk, let it do the wipe — set `forceWipeDevicesAndDestroyAllData: true` in the `LVMCluster` CR (see **Option A** above) and apply it. The operator tears down the stale volume group and rebuilds it cleanly. Always try this before manual disk surgery.

> **If an `LVMCluster` already exists and is holding the device**, delete it first, then re-apply with the wipe flag:
>
> ```bash
> oc get lvmcluster -A
> oc delete lvmcluster <name> -n openshift-storage
> ```
>
> Deletion can hang on finalizers if any PVCs are still bound — clear those consumers first.

### Manual reclaim (operator not managing the disk yet)

Run these on the SNO host. **Confirm you're targeting the data drive, not the OS drive** — in `lsblk`, the OS drive is the one carrying `/boot`, `/var`, and `/sysroot`.

```bash
# 1. Tear down the volume group and physical volume
sudo vgchange -an vg1
sudo vgremove -f vg1
sudo pvremove -ff /dev/nvme0n1

# 2. Wipe on-disk signatures and the partition table
sudo wipefs -a /dev/nvme0n1
sudo sgdisk --zap-all /dev/nvme0n1
```

If `vgchange` or `wipefs` still report the device is busy, stale device-mapper mappings are still active in the kernel. Clear them in dependency order — the thin volumes first, then the pool internals:

```bash
# Remove the thin volumes sitting on top of the pool
for d in $(sudo dmsetup ls | awk '/^vg1-/ {print $1}' | grep -vE 'tpool|_tdata|_tmeta'); do
  sudo dmsetup remove "$d"
done

# Then remove the pool internals
sudo dmsetup remove vg1-thin--pool--1-tpool
sudo dmsetup remove vg1-thin--pool--1_tdata
sudo dmsetup remove vg1-thin--pool--1_tmeta
```

> **Note — `partprobe` is not on RHCOS.** It ships with `parted`, which isn't included in the CoreOS image (`sudo: partprobe: command not found`). Re-read the partition table with `blockdev` instead, or just reboot:
>
> ```bash
> sudo blockdev --rereadpt /dev/nvme0n1
> sudo udevadm settle
> ```

### The reliable finish: reboot

Once the PV label, VG metadata, and GPT are wiped from disk, the simplest way to clear any lingering device-mapper mappings is a reboot. On boot, LVM auto-activation finds nothing to activate and the disk comes up clean:

```bash
sudo systemctl reboot
```

Verify afterward — you want a bare disk with no children:

```bash
lsblk /dev/nvme0n1
```

Then apply your `LVMCluster` (keep `forceWipeDevicesAndDestroyAllData: true` for good measure) and the operator provisions a fresh volume group on the empty device.

---

## LVMCluster Stuck `Progressing` or `Failed` — the Empty-Disk Trap

**Symptom.** The operator installs fine and the `LVMCluster` is created, but it never reaches `Ready`. The `vg-manager` log shows `vgcreate` failing over and over:

```
vgcreate vg1 --addtag @lvms /dev/sda /dev/nvme0n1
→ exit status 5: Cannot use /dev/sda: device not found.
  Command requires all devices to be found.
```

**Why it happens.** When the `LVMCluster` has **no `deviceSelector`**, LVMS *auto-discovers* and claims **every empty block device** on the node — not just your data disk. Most bare-metal machines expose a second empty device: a built-in SD/MMC card reader or an unused USB slot shows up as a **0-byte disk** (often `/dev/sda`). `vgcreate` requires *all* listed devices to open, so that phantom 0B device fails the whole command and the VG never forms. Auto-discovery is only safe on a VM with exactly one clean data disk.

Check what the operator sees:

```bash
oc -n openshift-lvm-storage logs -l app.kubernetes.io/component=vg-manager --tail=80
oc get lvmcluster sno-lvmcluster -n openshift-lvm-storage -o yaml   # look at status → nodeStatus
```

### The fix: pin the real data disk

Point the `LVMCluster` at a specific disk with a stable `by-id` path so the card reader is never in the list.

> ⚠️ **An `LVMCluster`'s `deviceClass` is immutable.** You cannot edit the device selection on the existing object — you must delete it first, or your change is silently ignored.

```bash
# 1. Delete the stuck cluster and wait for cleanup to finish
oc delete lvmcluster sno-lvmcluster -n openshift-lvm-storage --wait
oc get lvmcluster -n openshift-lvm-storage      # expect: No resources found

# 2. Find the stable path for your data disk (NOT the OS disk)
oc debug node/<node> -- chroot /host bash -c \
  'for l in /dev/disk/by-id/nvme-*; do [ "$(readlink -f "$l")" = /dev/nvme0n1 ] \
   && printf "/dev/disk/by-id/%s\n" "$(basename "$l")"; done | grep -v nvme-eui'
```

Then recreate the `LVMCluster` with an explicit `deviceSelector` (this is what the Day 2 playbook does when you pass `-e storage_device=…`):

```yaml
spec:
  storage:
    deviceClasses:
      - name: vg1
        default: true
        deviceSelector:
          paths:
            - /dev/disk/by-id/nvme-WD_Green_SN350_2TB_2321XXXXXXXX
          forceWipeDevicesAndDestroyAllData: true
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
```

With the disk pinned, LVMS ignores the 0B reader entirely and the VG comes up. **Takeaway for the team: on physical hardware, always pin the data disk by `by-id` path — never rely on auto-discovery.**

---

## Verify Storage End-to-End

After a rebuild, confirm the whole provisioning path actually works — StorageClass, volume group, thin pool, and mount — with a throwaway PVC and pod. This binds a real volume against `lvms-vg1`, writes to it, and cleans up in about 20 seconds:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lvms-smoke, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  storageClassName: lvms-vg1
---
apiVersion: v1
kind: Pod
metadata: { name: lvms-smoke, namespace: default }
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sh", "-c", "echo ok > /data/test && cat /data/test && sleep 5"]
      volumeMounts: [{ name: vol, mountPath: /data }]
  volumes:
    - name: vol
      persistentVolumeClaim: { claimName: lvms-smoke }
EOF

# Wait for the pod, read what it wrote, then clean up
oc -n default wait --for=condition=Ready pod/lvms-smoke --timeout=90s && oc -n default logs lvms-smoke
oc -n default delete pod/lvms-smoke pvc/lvms-smoke
```

If the logs print `ok`, provisioning is healthy end-to-end. If the PVC stays `Pending`, the StorageClass uses `WaitForFirstConsumer`, so the volume only provisions once the pod schedules — check `oc -n default describe pvc lvms-smoke` and the `topolvm` controller pods in `openshift-storage` / `openshift-lvm-storage`.

---

## Next Step

➡️ [Run the Day 2 playbook](../README.md#step-2--run-the-day-2-playbook)