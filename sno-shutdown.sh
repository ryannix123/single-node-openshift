#!/usr/bin/env bash
# =============================================================================
# sno-shutdown.sh — Safe Single Node OpenShift shutdown with cert rotation
# Author: Ryan Nix <ryan.nix@gmail.com>
# Repo:   https://github.com/ryannix123/single-node-openshift
#
# SNO clusters that sit idle for >24h can develop certificate issues on the
# next boot. This script forces cert rotation before shutdown so the cluster
# comes back healthy every time.
#
# Usage:
#   ./scripts/sno-shutdown.sh
#   ./scripts/sno-shutdown.sh --skip-rotation   # shutdown only, no cert rotation
# =============================================================================

set -euo pipefail

SKIP_ROTATION=false

for arg in "$@"; do
  case $arg in
    --skip-rotation) SKIP_ROTATION=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ── preflight ────────────────────────────────────────────────────────────────
command -v oc &>/dev/null || die "oc not found in PATH"
oc whoami &>/dev/null     || die "Not logged in to the cluster — run 'oc login' first"

# ── certificate rotation ──────────────────────────────────────────────────────
if [[ "$SKIP_ROTATION" == false ]]; then
  log "Forcing kube-apiserver certificate rotation..."

  # Annotate the node to force kubelet cert regeneration on next boot
  NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
  log "Node: $NODE"

  oc annotate node "$NODE" \
    machineconfiguration.openshift.io/currentConfig- \
    machineconfiguration.openshift.io/desiredConfig- \
    --overwrite 2>/dev/null || true

  # Approve any pending CSRs before shutting down
  log "Approving any pending certificate signing requests..."
  PENDING=$(oc get csr --no-headers 2>/dev/null | grep -c Pending || true)
  if [[ "$PENDING" -gt 0 ]]; then
    oc get csr -o name | xargs oc adm certificate approve
    log "Approved $PENDING CSR(s)"
  else
    log "No pending CSRs"
  fi

  log "Certificate rotation complete"
fi

# ── drain and shutdown ────────────────────────────────────────────────────────
NODE="${NODE:-$(oc get nodes -o jsonpath='{.items[0].metadata.name}')}"

log "Marking node $NODE as unschedulable..."
oc adm cordon "$NODE"

log "Shutting down the cluster node..."
# If running on the node itself, use systemctl; otherwise ssh
if hostname | grep -q "$NODE" 2>/dev/null || [[ "$(hostname -f 2>/dev/null)" == "$NODE" ]]; then
  sudo systemctl poweroff
else
  log "Not running on the node — attempting SSH shutdown"
  log "  ssh core@$NODE 'sudo systemctl poweroff'"
  ssh -o StrictHostKeyChecking=no "core@$NODE" 'sudo systemctl poweroff' || \
    die "SSH failed. Run: ssh core@$NODE 'sudo systemctl poweroff'"
fi
