# Single Node OpenShift Installation Guide

This guide covers deploying Single Node OpenShift using the Assisted Installer.

## Prerequisites

- A physical or virtual machine meeting the minimum requirements:
  - 8 vCPU (16+ recommended for operators)
  - 32GB RAM (64GB+ recommended for operators)
  - 120GB boot disk
  - Additional storage disk for LVM (recommended)
- Red Hat account with OpenShift subscription
- DNS configured for your cluster domain
- Network connectivity

## Minimum Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| vCPU | 8 | 16+ |
| Memory | 32GB | 64GB+ |
| Boot Disk | 120GB | 200GB |
| Data Disk | - | 500GB+ SSD |

## DNS Requirements

Configure the following DNS records (replace `sno.example.com` with your domain):

| Record | Type | Value |
|--------|------|-------|
| `api.sno.example.com` | A | `<node-ip>` |
| `api-int.sno.example.com` | A | `<node-ip>` |
| `*.apps.sno.example.com` | A | `<node-ip>` |

## Installation Methods

### Option 1: Assisted Installer (Recommended)

The Assisted Installer provides a guided web-based installation experience.

1. Navigate to [console.redhat.com/openshift/assisted-installer](https://console.redhat.com/openshift/assisted-installer/clusters)
2. Click **Create cluster**
3. Select **Datacenter** → **Bare metal (x86_64)**
4. Enter cluster details:
   - Cluster name: `sno`
   - Base domain: `example.com`
   - OpenShift version: 4.20 (or latest)
   - Select **Install single node OpenShift (SNO)**
5. Generate and download the discovery ISO
6. Boot your machine from the ISO
7. Wait for the host to be discovered in the Assisted Installer UI
8. Configure networking (static IP recommended for SNO)
9. Click **Install cluster**

Installation typically takes 45-60 minutes.

### Option 2: Agent-based Installer

For fully automated or disconnected installations, use the agent-based installer.

See the [OpenShift documentation](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html) for details.

## Post-Installation

After installation completes:

1. Download the kubeconfig file from the Assisted Installer UI
2. Configure your local environment:
   ```bash
   export KUBECONFIG=/path/to/kubeconfig
   oc whoami
   ```
3. Access the console at `https://console-openshift-console.apps.sno.example.com`
4. Get the kubeadmin password from the Assisted Installer UI

## Next Steps

Proceed to [Day 2 Operations](day2-operations.md) to configure:

- [LVM Storage](day2-operations.md#1-lvm-storage-operator)
- [Image Registry](day2-operations.md#2-configure-the-image-registry)
- [Monitoring](day2-operations.md#3-configure-metrics-persistence)
- [TLS Certificates](day2-operations.md#4-lets-encrypt-tls-certificates)

## Troubleshooting

### Cluster doesn't finish installing

Check the cluster events in the Assisted Installer UI. Common issues:
- DNS resolution failures
- Network connectivity issues
- Insufficient resources

### Can't access the console

Verify DNS is properly configured:
```bash
dig api.sno.example.com
dig console-openshift-console.apps.sno.example.com
```

### Cluster operators degraded after install

Wait 10-15 minutes for operators to settle. Check status with:
```bash
oc get clusteroperators
oc get co | grep -v "True.*False.*False"
```
