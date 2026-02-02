#!/bin/bash
#
# wipe-storage-drive.sh - Prepare a drive for use with the LVM Operator
# Author: Ryan Nix <ryan.nix@gmail.com>
#
# The LVM Operator cannot claim drives that have existing partition tables,
# filesystem signatures, or LVM metadata. This script wipes a drive clean.
#
# Usage: ./wipe-storage-drive.sh /dev/nvme0n1 [node-name]
#
# If node-name is not provided, uses the first node in the cluster.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $(basename "$0") DEVICE [NODE_NAME]

Wipe a storage drive for use with the LVM Operator.

Arguments:
    DEVICE      The device to wipe (e.g., /dev/nvme0n1, /dev/sdb)
    NODE_NAME   Optional: specific node name (default: first node in cluster)

Examples:
    $(basename "$0") /dev/nvme0n1
    $(basename "$0") /dev/sdb my-sno-node

WARNING: This will destroy ALL data on the specified drive!

EOF
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

DEVICE="$1"
NODE_NAME="${2:-}"

# Validate device path format
if [[ ! "$DEVICE" =~ ^/dev/ ]]; then
    log_error "Device must be a full path (e.g., /dev/nvme0n1)"
    exit 1
fi

# Check oc is available and logged in
if ! command -v oc &> /dev/null; then
    log_error "oc command not found"
    exit 1
fi

if ! oc whoami &> /dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi

# Get node name if not provided
if [[ -z "$NODE_NAME" ]]; then
    NODE_NAME=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
    log_info "Using node: $NODE_NAME"
fi

# Confirm with user
echo ""
log_warn "This will DESTROY ALL DATA on ${DEVICE} on node ${NODE_NAME}"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    log_info "Aborted."
    exit 0
fi

log_info "Wiping ${DEVICE} on ${NODE_NAME}..."

# Execute wipe commands on the node
oc debug "node/${NODE_NAME}" -- chroot /host bash -c "
    set -e
    DEVICE='${DEVICE}'
    
    echo 'Checking device...'
    if [[ ! -b \$DEVICE ]]; then
        echo 'ERROR: Device \$DEVICE does not exist'
        exit 1
    fi
    
    echo 'Removing filesystem signatures...'
    wipefs -a \$DEVICE || true
    
    echo 'Clearing partition table...'
    sgdisk --zap-all \$DEVICE || true
    
    echo 'Removing LVM metadata...'
    pvremove -ff \$DEVICE 2>/dev/null || true
    
    echo 'Zeroing first 10MB...'
    dd if=/dev/zero of=\$DEVICE bs=1M count=10 2>/dev/null || true
    
    echo 'Zeroing last 10MB (GPT backup)...'
    SECTORS=\$(blockdev --getsz \$DEVICE)
    SEEK=\$((SECTORS / 2048 - 10))
    dd if=/dev/zero of=\$DEVICE bs=1M seek=\$SEEK count=10 2>/dev/null || true
    
    echo 'Verifying device is clean...'
    lsblk -f \$DEVICE
    
    echo 'Done!'
"

log_info "Drive ${DEVICE} has been wiped and is ready for LVM"
log_info "You can now apply the LVMCluster configuration"
