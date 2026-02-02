# Day 2 Operations for Single Node OpenShift

After your SNO cluster is up and running, these Day 2 operations will configure storage, enable the internal registry, set up metrics persistence, and optionally deploy Red Hat Advanced Cluster Management and Ansible Automation Platform.

## Prerequisites

- A running Single Node OpenShift cluster
- `oc` CLI authenticated as cluster-admin
- An additional disk/partition for LVM storage (recommended: SSD)

---

## 1. LVM Storage Operator

The LVM Storage Operator provides dynamic provisioning of local storage using LVM, which is ideal for SNO deployments.

### Install the LVM Storage Operator

```yaml
# lvm-operator.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-lvm-storage
  labels:
    openshift.io/cluster-monitoring: "true"

---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-lvm-storage-operatorgroup
  namespace: openshift-lvm-storage
spec:
  targetNamespaces:
    - openshift-lvm-storage

---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-lvm-storage
spec:
  channel: stable-4.20
  installPlanApproval: Automatic
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

```bash
oc apply -f lvm-operator.yaml

# Wait for the operator to be ready
oc wait --for=condition=Available deployment/lvms-operator -n openshift-lvm-storage --timeout=300s
```

### Prepare the Storage Drive (Important!)

The LVM operator cannot use drives that have existing partition tables, filesystem signatures, or LVM metadata. If you're reusing a drive or the LVMCluster fails to become ready, you'll need to wipe the drive first.

```bash
# First, identify your storage drive
oc debug node/<node-name> -- chroot /host lsblk

# Wipe the drive (replace /dev/nvme0n1 with your actual device)
# WARNING: This destroys all data on the drive!
oc debug node/<node-name> -- chroot /host bash -c '
    DEVICE=/dev/nvme0n1
    
    # Remove any existing partitions
    wipefs -a $DEVICE
    
    # Clear partition table
    sgdisk --zap-all $DEVICE
    
    # Remove any LVM metadata
    pvremove -ff $DEVICE 2>/dev/null || true
    
    # Final wipe of first and last 10MB (catches GPT backup)
    dd if=/dev/zero of=$DEVICE bs=1M count=10 2>/dev/null
    dd if=/dev/zero of=$DEVICE bs=1M seek=$(($(blockdev --getsz $DEVICE) / 2048 - 10)) count=10 2>/dev/null
    
    echo "Drive $DEVICE wiped successfully"
'

# Verify the drive is clean
oc debug node/<node-name> -- chroot /host lsblk -f
```

Alternatively, you can create a MachineConfig to wipe the drive on boot (useful for automated deployments):

```yaml
# wipe-storage-drive.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-wipe-storage-drive
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
        - name: wipe-storage-drive.service
          enabled: true
          contents: |
            [Unit]
            Description=Wipe storage drive for LVM
            Before=local-fs-pre.target
            ConditionPathExists=!/var/lib/storage-drive-wiped

            [Service]
            Type=oneshot
            ExecStart=/usr/sbin/wipefs -a /dev/nvme0n1
            ExecStart=/usr/sbin/sgdisk --zap-all /dev/nvme0n1
            ExecStart=/usr/bin/touch /var/lib/storage-drive-wiped
            RemainAfterExit=yes

            [Install]
            WantedBy=multi-user.target
```

### Create an LVMCluster

This configuration targets a specific NVMe drive. Adjust the `deviceSelector.paths` to match your environment.

```yaml
# lvmcluster.yaml
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: openshift-lvm-storage
spec:
  storage:
    deviceClasses:
    - name: vg1
      deviceSelector:
        paths:
        - /dev/nvme0n1
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        overprovisionRatio: 10
```

```bash
oc apply -f lvmcluster.yaml

# Wait for the LVMCluster to be ready
oc wait --for=condition=Ready lvmcluster/my-lvmcluster -n openshift-lvm-storage --timeout=300s

# Wait for the StorageClass to be provisioned
oc wait --for=jsonpath='{.provisioner}'=topolvm.io storageclass/lvms-vg1 --timeout=120s

# Verify
oc get lvmcluster -n openshift-lvm-storage
oc get storageclass lvms-vg1
```

### Set LVM as the Default StorageClass

```bash
oc patch storageclass lvms-vg1 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Troubleshooting LVM Issues

If the LVMCluster stays in a pending state:

```bash
# Check the vg-manager pod logs
oc logs -n openshift-lvm-storage -l app.kubernetes.io/name=vg-manager

# Check for events
oc get events -n openshift-lvm-storage --sort-by='.lastTimestamp'

# Verify the drive is visible and clean
oc debug node/<node-name> -- chroot /host lsblk -f /dev/nvme0n1

# Common issues:
# - Drive has existing filesystem: run wipefs -a /dev/nvme0n1
# - Drive has LVM metadata: run pvremove -ff /dev/nvme0n1
# - Drive has partition table: run sgdisk --zap-all /dev/nvme0n1
```

---

## 2. Configure the Image Registry

By default, the OpenShift image registry is set to `Removed` on SNO because there's no shared storage. With LVM storage available, we can enable it.

### Create the Registry PVC

```yaml
# registry-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-storage
  namespace: openshift-image-registry
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
```

```bash
oc apply -f registry-pvc.yaml

# Verify PVC is bound
oc get pvc -n openshift-image-registry
```

### Enable the Registry with Persistent Storage

```bash
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
  -p '{"spec":{"managementState":"Managed","storage":{"pvc":{"claim":"registry-storage"}},"rolloutStrategy":"Recreate"}}'
```

### Verify the Registry is Running

```bash
# Check the registry pods
oc get pods -n openshift-image-registry

# Verify the registry is accessible
oc get co image-registry

# Test by tagging an image into the internal registry
oc tag --source=docker registry.redhat.io/ubi8/ubi:latest ubi:latest -n openshift
```

---

## 3. Configure Metrics Persistence

By default, Prometheus metrics are stored ephemerally. Configuring persistent storage ensures metrics survive pod restarts.

### Create the Cluster Monitoring ConfigMap

```yaml
# cluster-monitoring-config.yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    prometheusK8s: 
      volumeClaimTemplate:
        spec:
          storageClassName: lvms-vg1
          volumeMode: Filesystem
          resources:
            requests:
              storage: 40Gi
    enableUserWorkload: true
```

```bash
oc apply -f cluster-monitoring-config.yaml

# The monitoring stack will automatically restart and create PVCs
# Watch the pods restart
oc get pods -n openshift-monitoring -w
```

> **Note:** `enableUserWorkload: true` enables monitoring for user-defined projects, allowing your applications to expose custom metrics that Prometheus will scrape.

### Verify Metrics Persistence

```bash
# Check the PVCs were created
oc get pvc -n openshift-monitoring

# Verify Prometheus is running with persistent storage
oc get pods -n openshift-monitoring | grep prometheus
```

---

## 4. Let's Encrypt TLS Certificates

Replace the self-signed ingress certificates with trusted Let's Encrypt certificates. This eliminates browser warnings and enables proper TLS verification for your applications.

### Prerequisites

- A domain you control (e.g., `apps.sno.openshifthelp.com`)
- DNS access to create TXT records for validation
- `certbot` installed on your local machine

### Generate the Wildcard Certificate

Let's Encrypt requires DNS validation for wildcard certificates. Run certbot and follow the prompts to create the required DNS TXT record:

```bash
# Create a working directory for Let's Encrypt files
mkdir -p ~/letsencrypt-sno

# Request a wildcard certificate
certbot certonly \
  --manual \
  --preferred-challenges dns \
  -d '*.apps.sno.openshifthelp.com' \
  --config-dir ~/letsencrypt-sno \
  --work-dir ~/letsencrypt-sno \
  --logs-dir ~/letsencrypt-sno
```

Certbot will prompt you to create a DNS TXT record like:
```
_acme-challenge.apps.sno.openshifthelp.com  TXT  "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

Create this record in your DNS provider, wait for propagation (verify with `dig TXT _acme-challenge.apps.sno.openshifthelp.com`), then press Enter to continue.

### Configure OpenShift to Use the Certificate

Once certbot completes, you'll have certificates in `~/letsencrypt-sno/live/apps.sno.openshifthelp.com/`. Use a unique suffix (like a date) to allow easy certificate rotation later.

```bash
# Set variables for easier management
CERT_DIR=~/letsencrypt-sno/live/apps.sno.openshifthelp.com
CERT_SUFFIX=$(date +%m%d%y)  # e.g., 020226

# Create the CA ConfigMap (for cluster-wide trust)
oc create configmap letsencrypt-ca-${CERT_SUFFIX} \
  --from-file=ca-bundle.crt="${CERT_DIR}/fullchain.pem" \
  -n openshift-config

# Configure the cluster proxy to trust the CA
oc patch proxy/cluster \
  --type=merge \
  --patch="{\"spec\":{\"trustedCA\":{\"name\":\"letsencrypt-ca-${CERT_SUFFIX}\"}}}"

# Create the TLS secret for the ingress controller
oc create secret tls letsencrypt-tls-${CERT_SUFFIX} \
  --cert="${CERT_DIR}/fullchain.pem" \
  --key="${CERT_DIR}/privkey.pem" \
  -n openshift-ingress

# Configure the ingress controller to use the certificate
oc patch ingresscontroller.operator default \
  --type=merge \
  -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"letsencrypt-tls-${CERT_SUFFIX}\"}}}" \
  -n openshift-ingress-operator
```

### Verify the Certificate

```bash
# Check the ingress controller is using the new certificate
oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}'

# Wait for the router pods to restart
oc get pods -n openshift-ingress -w

# Test the certificate (should show Let's Encrypt as issuer)
echo | openssl s_client -connect console-openshift-console.apps.sno.openshifthelp.com:443 2>/dev/null | openssl x509 -noout -issuer -dates
```

### Certificate Renewal

Let's Encrypt certificates expire after 90 days. To renew:

```bash
# Renew the certificate
certbot renew \
  --config-dir ~/letsencrypt-sno \
  --work-dir ~/letsencrypt-sno \
  --logs-dir ~/letsencrypt-sno

# After renewal, update the OpenShift secrets with a new suffix
NEW_SUFFIX=$(date +%m%d%y)

# Delete old and create new (or use oc create --dry-run=client -o yaml | oc apply -f -)
oc create secret tls letsencrypt-tls-${NEW_SUFFIX} \
  --cert="${CERT_DIR}/fullchain.pem" \
  --key="${CERT_DIR}/privkey.pem" \
  -n openshift-ingress \
  --dry-run=client -o yaml | oc apply -f -

oc patch ingresscontroller.operator default \
  --type=merge \
  -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"letsencrypt-tls-${NEW_SUFFIX}\"}}}" \
  -n openshift-ingress-operator

# Clean up old secrets
oc delete secret letsencrypt-tls-${OLD_SUFFIX} -n openshift-ingress
oc delete configmap letsencrypt-ca-${OLD_SUFFIX} -n openshift-config
```

### Automating Renewal (Optional)

Create a renewal script and schedule it with cron:

```bash
#!/bin/bash
# renew-letsencrypt.sh

CERT_DIR=~/letsencrypt-sno/live/apps.sno.openshifthelp.com
CERT_SUFFIX=$(date +%m%d%y)

# Renew if needed
certbot renew --config-dir ~/letsencrypt-sno --work-dir ~/letsencrypt-sno --logs-dir ~/letsencrypt-sno

# Update OpenShift
oc create secret tls letsencrypt-tls-${CERT_SUFFIX} \
  --cert="${CERT_DIR}/fullchain.pem" \
  --key="${CERT_DIR}/privkey.pem" \
  -n openshift-ingress \
  --dry-run=client -o yaml | oc apply -f -

oc patch ingresscontroller.operator default \
  --type=merge \
  -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"letsencrypt-tls-${CERT_SUFFIX}\"}}}" \
  -n openshift-ingress-operator
```

```bash
# Add to crontab (runs weekly)
0 3 * * 0 /path/to/renew-letsencrypt.sh >> /var/log/letsencrypt-renewal.log 2>&1
```

---

## 5. Ansible Automation Platform (AAP) 2.6

AAP 2.6 uses a unified gateway architecture. The `AnsibleAutomationPlatform` CR manages all components.

### Deploy AAP

Apply in stages since CRDs don't exist until the operator installs:

```yaml
# aap-deployment.yaml
# Stage 1: oc apply -f aap-deployment.yaml -l stage=1
# Stage 2: oc apply -f aap-deployment.yaml -l stage=2

---
# Stage 1: Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: aap
  labels:
    stage: "1"

---
# Stage 1: OperatorGroup
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: aap-operator-group
  namespace: aap
  labels:
    stage: "1"
spec:
  targetNamespaces:
    - aap

---
# Stage 1: Subscription
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ansible-automation-platform-operator
  namespace: aap
  labels:
    stage: "1"
spec:
  channel: stable-2.6
  installPlanApproval: Automatic
  name: ansible-automation-platform-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace

---
# Stage 2: AnsibleAutomationPlatform
apiVersion: aap.ansible.com/v1alpha1
kind: AnsibleAutomationPlatform
metadata:
  name: aap
  namespace: aap
  labels:
    stage: "2"
spec:
  gateway:
    replicas: 1
  controller:
    disabled: false
  # Disable hub/eda to save resources on SNO
  hub:
    disabled: true
  eda:
    disabled: true
```

```bash
# Stage 1: Install the operator
oc apply -f aap-deployment.yaml -l stage=1

# Wait for the operator to be ready
oc wait --for=condition=CatalogSourcesUnhealthy=False \
  subscription/ansible-automation-platform-operator -n aap --timeout=300s

# Verify CRDs are available
oc get crd | grep ansible

# Stage 2: Deploy the platform
oc apply -f aap-deployment.yaml -l stage=2

# Watch the deployment
oc get pods -n aap -w
```

### Access AAP

```bash
# Get the AAP route (use the gateway route, not the controller route)
oc get routes -n aap

# Get the admin password
oc get secret aap-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d && echo
```

Access the platform at the gateway URL (e.g., `https://aap-aap.apps.<cluster-domain>`). The username is `admin`.

> **Note:** Do not access the `controller` route directly - the gateway handles all authentication in AAP 2.5+.

---

## 6. Red Hat Advanced Cluster Management (ACM)

ACM provides multi-cluster management capabilities. Even on SNO, it's useful as a hub for managing other clusters.

### Deploy ACM

```yaml
# acm-deployment.yaml
# Stage 1: oc apply -f acm-deployment.yaml -l stage=1
# Stage 2: oc apply -f acm-deployment.yaml -l stage=2

---
# Stage 1: Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
  labels:
    stage: "1"

---
# Stage 1: OperatorGroup
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: acm-operator-group
  namespace: open-cluster-management
  labels:
    stage: "1"
spec:
  targetNamespaces:
    - open-cluster-management

---
# Stage 1: Subscription
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
  labels:
    stage: "1"
spec:
  channel: release-2.12
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace

---
# Stage 2: MultiClusterHub
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
  labels:
    stage: "2"
spec: {}
```

```bash
# Stage 1: Install the operator
oc apply -f acm-deployment.yaml -l stage=1

# Wait for the operator
oc wait --for=condition=Available deployment/multiclusterhub-operator \
  -n open-cluster-management --timeout=600s

# Stage 2: Deploy the MultiClusterHub
oc apply -f acm-deployment.yaml -l stage=2

# Watch deployment (this takes 10-15 minutes)
oc get mch -n open-cluster-management -w
```

### Access ACM

```bash
# Get the ACM console route
oc get routes -n open-cluster-management | grep multicloud

# ACM uses OpenShift authentication - log in with kubeadmin or an OAuth user
```

---

## 7. OpenShift Virtualization (Optional)

If you want to run VMs alongside containers:

```yaml
# cnv-deployment.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv

---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv

---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace

---
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  infra: {}
  workloads: {}
```

```bash
oc apply -f cnv-deployment.yaml

# Wait for the HyperConverged CR to be ready
oc get hco -n openshift-cnv -w
```

---

## 8. Graceful Shutdown and Startup

If you're running SNO in a home lab, you'll likely want to shut it down when not in use. OpenShift certificates can expire if the cluster is powered off for extended periods, so it's important to handle shutdown properly.

### The Certificate Problem

OpenShift uses short-lived certificates (typically 30 days) that automatically rotate while the cluster is running. If your SNO is powered off and certificates expire, the cluster won't start properly. The safe shutdown script below checks for certificates expiring soon and triggers rotation before shutdown.

### Safe Shutdown Script

Save this script as `sno-shutdown.sh`:

```bash
#!/bin/bash
#
# sno-shutdown.sh - Safe shutdown for Single Node OpenShift with certificate rotation
# Author: Ryan Nix <ryan.nix@gmail.com>
# 
# This script checks for certificates expiring within a configurable window
# and triggers rotation before shutting down the cluster.
#

set -euo pipefail

# Configuration
EXPIRY_THRESHOLD_DAYS=${EXPIRY_THRESHOLD_DAYS:-14}
ROTATION_WAIT_SECONDS=${ROTATION_WAIT_SECONDS:-300}
SHUTDOWN_DELAY_MINUTES=${SHUTDOWN_DELAY_MINUTES:-1}
DRY_RUN=${DRY_RUN:-false}
VERBOSE=${VERBOSE:-false}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Safe shutdown for Single Node OpenShift with automatic certificate rotation.

Options:
    -d, --days DAYS         Days before expiry to trigger rotation (default: 14)
    -w, --wait SECONDS      Seconds to wait after triggering rotation (default: 300)
    -s, --shutdown MINUTES  Shutdown delay in minutes (default: 1)
    -n, --dry-run           Check certificates but don't rotate or shutdown
    -v, --verbose           Enable verbose output
    -h, --help              Show this help message

Environment Variables:
    EXPIRY_THRESHOLD_DAYS   Same as --days
    ROTATION_WAIT_SECONDS   Same as --wait
    SHUTDOWN_DELAY_MINUTES  Same as --shutdown
    DRY_RUN                 Same as --dry-run (set to 'true')
    VERBOSE                 Same as --verbose (set to 'true')

Examples:
    # Normal shutdown with 14-day threshold
    $(basename "$0")

    # Check certificates without shutdown
    $(basename "$0") --dry-run

    # Rotate certs expiring in 30 days, verbose output
    $(basename "$0") --days 30 --verbose

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--days)
            EXPIRY_THRESHOLD_DAYS="$2"
            shift 2
            ;;
        -w|--wait)
            ROTATION_WAIT_SECONDS="$2"
            shift 2
            ;;
        -s|--shutdown)
            SHUTDOWN_DELAY_MINUTES="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v oc &> /dev/null; then
        log_error "oc command not found. Please install the OpenShift CLI."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq command not found. Please install jq."
        exit 1
    fi
    
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift cluster. Please run 'oc login' first."
        exit 1
    fi
    
    log_info "Logged in as: $(oc whoami)"
    log_info "Cluster: $(oc whoami --show-server)"
}

# Get certificates expiring within threshold
get_expiring_certs() {
    local threshold_seconds=$((EXPIRY_THRESHOLD_DAYS * 86400))
    local now_epoch=$(date +%s)
    local threshold_epoch=$((now_epoch + threshold_seconds))
    
    log_info "Checking for certificates expiring within ${EXPIRY_THRESHOLD_DAYS} days..."
    log_debug "Current time: $(date -d @${now_epoch})"
    log_debug "Threshold time: $(date -d @${threshold_epoch})"
    
    # Method 1: Check secrets with auth.openshift.io/certificate-not-after annotation
    log_debug "Checking secrets with certificate-not-after annotation..."
    
    local expiring_secrets
    expiring_secrets=$(oc get secrets -A -o json 2>/dev/null | jq -r --argjson threshold "$threshold_epoch" '
        .items[] | 
        select(.metadata.annotations["auth.openshift.io/certificate-not-after"] != null) |
        select((.metadata.annotations["auth.openshift.io/certificate-not-after"] | fromdateiso8601) <= $threshold) |
        "\(.metadata.namespace)/\(.metadata.name)|\(.metadata.annotations["auth.openshift.io/certificate-not-after"])"
    ' 2>/dev/null || echo "")
    
    # Method 2: Check TLS secrets by decoding certificates
    log_debug "Checking TLS secrets for expiration..."
    
    local tls_expiring=""
    while IFS=' ' read -r namespace name cert; do
        if [[ -n "$cert" && "$cert" != "null" ]]; then
            local expiry_date
            expiry_date=$(echo "$cert" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
            if [[ -n "$expiry_date" ]]; then
                local expiry_epoch
                expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
                if [[ "$expiry_epoch" -le "$threshold_epoch" && "$expiry_epoch" -gt 0 ]]; then
                    tls_expiring+="${namespace}/${name}|${expiry_date}"$'\n'
                fi
            fi
        fi
    done < <(oc get secrets -A -o go-template='{{range .items}}{{if eq .type "kubernetes.io/tls"}}{{.metadata.namespace}} {{.metadata.name}} {{index .data "tls.crt"}}{{"\n"}}{{end}}{{end}}' 2>/dev/null)
    
    # Combine and dedupe results
    echo -e "${expiring_secrets}\n${tls_expiring}" | grep -v '^$' | sort -u
}

# Check pending CSRs
check_pending_csrs() {
    log_info "Checking for pending Certificate Signing Requests..."
    
    local pending_csrs
    pending_csrs=$(oc get csr -o json 2>/dev/null | jq -r '.items[] | select(.status.certificate == null) | .metadata.name' || echo "")
    
    if [[ -n "$pending_csrs" ]]; then
        log_warn "Found pending CSRs:"
        echo "$pending_csrs" | while read -r csr; do
            log_warn "  - $csr"
        done
        return 1
    fi
    
    log_info "No pending CSRs found."
    return 0
}

# Approve any pending CSRs
approve_pending_csrs() {
    log_info "Approving pending CSRs..."
    
    local approved=0
    for csr in $(oc get csr -o json 2>/dev/null | jq -r '.items[] | select(.status.certificate == null) | .metadata.name'); do
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would approve CSR: $csr"
        else
            log_info "Approving CSR: $csr"
            oc adm certificate approve "$csr" 2>/dev/null || log_warn "Failed to approve CSR: $csr"
            ((approved++))
        fi
    done
    
    if [[ $approved -gt 0 ]]; then
        log_info "Approved $approved CSR(s). Waiting for processing..."
        sleep 10
    fi
}

# Trigger certificate rotation by clearing the not-after annotation
trigger_cert_rotation() {
    local threshold_seconds=$((EXPIRY_THRESHOLD_DAYS * 86400))
    local threshold_epoch=$(($(date +%s) + threshold_seconds))
    
    log_info "Triggering rotation for certificates expiring within ${EXPIRY_THRESHOLD_DAYS} days..."
    
    # Get secrets that need rotation
    local secrets_to_rotate
    secrets_to_rotate=$(oc get secrets -A -o json 2>/dev/null | jq -r --argjson threshold "$threshold_epoch" '
        .items[] | 
        select(.metadata.annotations["auth.openshift.io/certificate-not-after"] != null) |
        select((.metadata.annotations["auth.openshift.io/certificate-not-after"] | fromdateiso8601) <= $threshold) |
        "-n \(.metadata.namespace) \(.metadata.name)"
    ' 2>/dev/null || echo "")
    
    if [[ -z "$secrets_to_rotate" ]]; then
        log_info "No secrets with certificate-not-after annotation need rotation."
        return 0
    fi
    
    local rotated=0
    echo "$secrets_to_rotate" | while read -r args; do
        if [[ -n "$args" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY-RUN] Would trigger rotation for secret: $args"
            else
                log_info "Triggering rotation for: $args"
                # shellcheck disable=SC2086
                oc patch secret $args -p='{"metadata": {"annotations": {"auth.openshift.io/certificate-not-after": null}}}' 2>/dev/null || \
                    log_warn "Failed to patch secret: $args"
                ((rotated++))
            fi
        fi
    done
    
    return 0
}

# Wait for cluster operators to stabilize
wait_for_stable_cluster() {
    log_info "Waiting for cluster to stabilize (up to ${ROTATION_WAIT_SECONDS} seconds)..."
    
    local start_time=$(date +%s)
    local end_time=$((start_time + ROTATION_WAIT_SECONDS))
    local stable_count=0
    local required_stable=3  # Require 3 consecutive stable checks
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local degraded
        degraded=$(oc get clusteroperators -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[] | select(.type == "Degraded" and .status == "True"))] | length' || echo "999")
        
        local progressing
        progressing=$(oc get clusteroperators -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[] | select(.type == "Progressing" and .status == "True"))] | length' || echo "999")
        
        log_debug "Degraded: $degraded, Progressing: $progressing"
        
        if [[ "$degraded" == "0" && "$progressing" == "0" ]]; then
            ((stable_count++))
            log_debug "Stable check $stable_count of $required_stable"
            if [[ $stable_count -ge $required_stable ]]; then
                log_info "Cluster is stable."
                return 0
            fi
        else
            stable_count=0
            log_info "Cluster stabilizing... (Degraded: $degraded, Progressing: $progressing)"
        fi
        
        sleep 30
    done
    
    log_warn "Cluster did not fully stabilize within ${ROTATION_WAIT_SECONDS} seconds."
    log_warn "Proceeding with shutdown anyway..."
    return 1
}

# Check API server certificate expiration
check_api_cert() {
    log_info "Checking API server certificate..."
    
    local api_server
    api_server=$(oc whoami --show-server | sed 's|https://||' | cut -d: -f1)
    local api_port
    api_port=$(oc whoami --show-server | sed 's|https://||' | cut -d: -f2)
    api_port=${api_port:-6443}
    
    local cert_info
    cert_info=$(echo | timeout 10 openssl s_client -connect "${api_server}:${api_port}" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "")
    
    if [[ -n "$cert_info" ]]; then
        log_info "API server certificate info:"
        echo "$cert_info" | while read -r line; do
            log_info "  $line"
        done
        
        local end_date
        end_date=$(echo "$cert_info" | grep notAfter | cut -d= -f2)
        local end_epoch
        end_epoch=$(date -d "$end_date" +%s 2>/dev/null || echo "0")
        local now_epoch=$(date +%s)
        local days_remaining=$(( (end_epoch - now_epoch) / 86400 ))
        
        if [[ $days_remaining -le $EXPIRY_THRESHOLD_DAYS ]]; then
            log_warn "API server certificate expires in $days_remaining days!"
            return 1
        else
            log_info "API server certificate valid for $days_remaining more days."
        fi
    else
        log_warn "Could not retrieve API server certificate info."
    fi
    
    return 0
}

# Perform the actual shutdown
perform_shutdown() {
    log_info "Initiating shutdown sequence..."
    
    for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY-RUN] Would shutdown node: $node (delay: ${SHUTDOWN_DELAY_MINUTES} minutes)"
        else
            log_info "Shutting down node: $node (delay: ${SHUTDOWN_DELAY_MINUTES} minutes)"
            oc debug "node/${node}" -- chroot /host shutdown -h "$SHUTDOWN_DELAY_MINUTES" 2>/dev/null || \
                log_error "Failed to initiate shutdown on node: $node"
        fi
    done
}

# Generate certificate status report
generate_report() {
    log_info "=============================================="
    log_info "Certificate Status Report"
    log_info "=============================================="
    
    local expiring
    expiring=$(get_expiring_certs)
    
    if [[ -n "$expiring" ]]; then
        log_warn "Certificates expiring within ${EXPIRY_THRESHOLD_DAYS} days:"
        echo "$expiring" | while IFS='|' read -r secret expiry; do
            log_warn "  - $secret (expires: $expiry)"
        done
    else
        log_info "No certificates expiring within ${EXPIRY_THRESHOLD_DAYS} days."
    fi
    
    check_api_cert
    
    log_info "=============================================="
}

# Main execution
main() {
    log_info "SNO Safe Shutdown Script"
    log_info "Expiry threshold: ${EXPIRY_THRESHOLD_DAYS} days"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Running in DRY-RUN mode - no changes will be made"
    fi
    
    echo ""
    
    # Check prerequisites
    check_prerequisites
    echo ""
    
    # Generate initial report
    generate_report
    echo ""
    
    # Check for expiring certificates
    local expiring_certs
    expiring_certs=$(get_expiring_certs)
    
    if [[ -n "$expiring_certs" ]]; then
        log_warn "Found certificates that will expire soon!"
        
        # Approve any pending CSRs first
        approve_pending_csrs
        
        # Trigger rotation
        trigger_cert_rotation
        
        if [[ "$DRY_RUN" != "true" ]]; then
            # Wait for cluster to stabilize
            wait_for_stable_cluster
            
            # Check again after rotation
            echo ""
            log_info "Re-checking certificates after rotation..."
            generate_report
        fi
    else
        log_info "All certificates are valid beyond the ${EXPIRY_THRESHOLD_DAYS}-day threshold."
    fi
    
    echo ""
    
    # Perform shutdown
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would proceed with shutdown"
    else
        perform_shutdown
    fi
    
    log_info "Done."
}

main "$@"
```

### Using the Shutdown Script

```bash
# Make executable
chmod +x sno-shutdown.sh

# Check certificate status without shutting down
./sno-shutdown.sh --dry-run

# Normal shutdown (rotates certs expiring within 14 days)
./sno-shutdown.sh

# Rotate certs expiring within 30 days before shutdown
./sno-shutdown.sh --days 30

# Verbose output for troubleshooting
./sno-shutdown.sh --dry-run --verbose
```

### Starting Up After Shutdown

When you power the SNO node back on, the cluster should start automatically. However, you may need to approve pending CSRs if certificates were close to expiration:

```bash
# Wait for the API to become available (may take 5-10 minutes)
until oc get nodes 2>/dev/null; do
    echo "Waiting for API server..."
    sleep 30
done

# Check for pending CSRs
oc get csr

# Approve all pending CSRs (review them first in production)
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | \
    xargs -r oc adm certificate approve

# Watch cluster operators recover
oc get co -w

# Check for any degraded operators
oc get co | grep -v "True.*False.*False"
```

### Recovery from Expired Certificates

If your cluster has been down too long and certificates have expired, you'll need to perform certificate recovery. This is more involved:

```bash
# SSH to the node directly
ssh core@<sno-ip>

# Check kubelet status
sudo systemctl status kubelet

# If kubelet can't start due to cert issues, you may need to:
# 1. Recover the kube-apiserver certificates
# 2. Approve pending CSRs from the node itself

# Force certificate renewal (from the node)
sudo -i
cd /etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs

# Check certificate expiration
openssl x509 -in /etc/kubernetes/kubelet-ca.crt -noout -dates
```

For severe certificate expiration issues, refer to the [OpenShift documentation on certificate recovery](https://docs.openshift.com/container-platform/latest/backup_and_restore/control_plane_backup_and_restore/disaster_recovery/scenario-3-expired-certs.html).

### Scheduling Regular Certificate Checks

If your SNO runs continuously, consider a cron job to monitor certificate health:

```bash
# Add to crontab (runs daily at 6 AM)
0 6 * * * /path/to/sno-shutdown.sh --dry-run 2>&1 | mail -s "SNO Cert Check" you@example.com
```

---

## Quick Reference: Useful Commands

```bash
# Check all cluster operators
oc get co

# Check storage classes
oc get sc

# Check PVCs across all namespaces  
oc get pvc -A

# Check operator subscriptions
oc get sub -A

# Check node resources
oc adm top nodes

# Check pod resources
oc adm top pods -A --sort-by=memory
```

---

## Resource Considerations for SNO

Running multiple operators on SNO can be resource-intensive. Recommended minimums:

| Configuration | CPU | Memory | Storage |
|---------------|-----|--------|---------|
| Base SNO | 8 | 32GB | 120GB |
| + LVM + Registry | 8 | 32GB | 120GB + data disk |
| + AAP | 12 | 48GB | 120GB + 100GB data |
| + ACM | 16 | 64GB | 120GB + 200GB data |
| + OpenShift Virt | 16+ | 64GB+ | 120GB + 500GB+ data |

Consider disabling unused components (e.g., `hub` and `eda` in AAP) to reduce resource usage.
