# Single Node OpenShift

**The complete guide to running OpenShift in your home lab, on a single machine.**

<p align="left">
  <img src="https://upload.wikimedia.org/wikipedia/commons/3/3a/OpenShift-LogoType.svg" alt="OpenShift Logo" width="400">
</p>

Many people have used this repo to get OpenShift running on everything from Intel NUCs to enterprise servers. Whether you're learning Kubernetes, building a home lab, or need a portable demo environment, Single Node OpenShift (SNO) is a great way to get started with enterprise grade Kubernetes!

## Watch the Tutorials

These step-by-step video guides have helped nearly **15,000 viewers** get their SNO clusters up and running:

- [Single Node OpenShift Installation Walkthrough](https://youtu.be/leJa9HmvdI0) - Complete installation using the Assisted Installer
- [OpenShift Virtualization - Containers and VMs on the same control plane](https://youtu.be/ZV7KGqcPs7s) - Run containers and virtual machines side-by-side

## What You Get

This repository contains everything you need to go from bare metal to a fully functional OpenShift cluster:

**Installation** - Step-by-step instructions using Red Hat's Assisted Installer, the easiest way to deploy OpenShift on physical or virtual hardware.

**Storage Configuration** - Ready-to-use manifests for the LVM Operator, including the fix for that annoying "drive not recognized" issue that trips up most people.

**Production-Ready TLS** - Replace those self-signed certificates with real Let's Encrypt certs. No more browser warnings.

**Operator Deployments** - Pre-configured manifests for Ansible Automation Platform, Advanced Cluster Management, and OpenShift Virtualization. Just `oc apply` and go.

**Safe Shutdown Scripts** - SNO clusters that sit idle can develop certificate problems. The included shutdown script handles certificate rotation automatically before powering down.

## Quick Start

```bash
# Clone the repo
git clone https://github.com/ryannix123/single-node-openshift.git
cd single-node-openshift

# Follow the installation guide
# Then apply storage configuration
oc apply -f manifests/storage/lvm-operator.yaml
oc apply -f manifests/storage/lvmcluster.yaml
oc apply -f manifests/storage/registry-pvc.yaml
```

## Repository Layout

```
docs/
  installation.md        # Getting SNO installed
  day2-operations.md     # Everything after installation

manifests/
  storage/               # LVM operator, registry PVC
  monitoring/            # Prometheus persistence
  operators/
    aap/                 # Ansible Automation Platform 2.6
    acm/                 # Advanced Cluster Management
    cnv/                 # OpenShift Virtualization
  tls/                   # Let's Encrypt configuration

scripts/
  sno-shutdown.sh        # Safe shutdown with cert rotation
  wipe-storage-drive.sh  # Prepare drives for LVM
  renew-letsencrypt.sh   # Certificate renewal
```

## Hardware Requirements

SNO is surprisingly resource-efficient. Here's what you need:

| Setup | CPU | RAM | Storage |
|-------|-----|-----|---------|
| Base cluster | 8 cores | 32GB | 120GB + data disk |
| With AAP | 12 cores | 48GB | 120GB + 100GB |
| With ACM | 16 cores | 64GB | 120GB + 200GB |
| Full stack | 16+ cores | 64GB+ | 120GB + 500GB |

An NVMe drive for your data disk makes a noticeable difference in performance.

## Why Single Node OpenShift?

**Learning** - Get hands-on experience with the same platform running in production at thousands of enterprises, without needing three machines.

**Development** - Test your applications on real OpenShift before deploying to shared environments. Break things without breaking your team.

**Edge & Remote** - SNO is designed for locations where high availability isn't practical but you still need the OpenShift developer experience.

**Demos** - Show customers or stakeholders real OpenShift capabilities on hardware you control.

## Tested With

- OpenShift 4.17, 4.18, 4.19, 4.20
- Ansible Automation Platform 2.5, 2.6
- Advanced Cluster Management 2.10, 2.11, 2.12

## Contributing

Found a bug? Have a better way to do something? PRs and issues are welcome.

## About

Created by Ryan Nix. This is a personal project to help the OpenShift community—not an official Red Hat resource.

If this repo helped you, consider giving it a star. It helps others find it too.