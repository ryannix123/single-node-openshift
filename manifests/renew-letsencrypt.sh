#!/usr/bin/env bash
# =============================================================================
# renew-letsencrypt.sh — Renew Let's Encrypt certs for Single Node OpenShift
# Author: Ryan Nix <ryan.nix@gmail.com>
# Repo:   https://github.com/ryannix123/single-node-openshift
#
# Obtains or renews Let's Encrypt TLS certificates and patches the OpenShift
# API server and ingress controller to use them.
#
# Prerequisites:
#   certbot installed  (dnf install certbot  or  brew install certbot)
#   oc logged in as cluster-admin
#
# Usage:
#   ./scripts/renew-letsencrypt.sh \
#     --cluster-name sno \
#     --base-domain   example.com \
#     --email         you@example.com
#
# DNS requirements:
#   api.<cluster-name>.<base-domain>    → <node-ip>
#   *.apps.<cluster-name>.<base-domain> → <node-ip>
#
# For clusters not reachable from the internet, switch to a DNS-01 challenge
# by exporting your DNS provider credentials before running this script.
# See: https://certbot.eff.org/docs/using.html#dns-plugins
# =============================================================================

set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────────────
CLUSTER_NAME=""
BASE_DOMAIN=""
EMAIL=""
CERT_DIR="/etc/letsencrypt/live"

# ── helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
  echo "Usage: $0 --cluster-name <name> --base-domain <domain> --email <email>"
  exit 1
}

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --base-domain)  BASE_DOMAIN="$2";  shift 2 ;;
    --email)        EMAIL="$2";        shift 2 ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$CLUSTER_NAME" || -z "$BASE_DOMAIN" || -z "$EMAIL" ]] && usage

API_DOMAIN="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
APPS_DOMAIN="apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
CERT_PATH="${CERT_DIR}/${API_DOMAIN}"

# ── preflight ─────────────────────────────────────────────────────────────────
command -v certbot &>/dev/null || die "certbot not found — install it first"
command -v oc      &>/dev/null || die "oc not found in PATH"
oc whoami          &>/dev/null || die "Not logged in — run 'oc login' first"

# ── obtain / renew certificates ───────────────────────────────────────────────
log "Requesting certificates for:"
log "  API:  $API_DOMAIN"
log "  Apps: *.${APPS_DOMAIN}"

sudo certbot certonly \
  --standalone \
  --preferred-challenges http \
  --agree-tos \
  --non-interactive \
  --email "$EMAIL" \
  -d "$API_DOMAIN" \
  -d "*.${APPS_DOMAIN}"

log "Certificate obtained: ${CERT_PATH}"

# ── create / update secrets in OpenShift ─────────────────────────────────────
log "Creating ingress TLS secret..."
oc create secret tls letsencrypt-ingress-cert \
  --cert="${CERT_PATH}/fullchain.pem" \
  --key="${CERT_PATH}/privkey.pem" \
  -n openshift-ingress \
  --dry-run=client -o yaml | oc apply -f -

log "Creating API server TLS secret..."
oc create secret tls letsencrypt-api-cert \
  --cert="${CERT_PATH}/fullchain.pem" \
  --key="${CERT_PATH}/privkey.pem" \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -

# ── patch ingress controller ──────────────────────────────────────────────────
log "Patching ingress controller to use new cert..."
oc patch ingresscontroller default \
  -n openshift-ingress-operator \
  --type=merge \
  -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"letsencrypt-ingress-cert\"}}}"

# ── patch API server ───────────────────────────────────────────────────────────
log "Patching API server to use new cert..."
oc patch apiserver cluster \
  --type=merge \
  -p "{\"spec\":{\"servingCerts\":{\"namedCertificates\":[{\"names\":[\"${API_DOMAIN}\"],\"servingCertificate\":{\"name\":\"letsencrypt-api-cert\"}}]}}}"

# ── wait for rollout ──────────────────────────────────────────────────────────
log "Waiting for ingress operator to roll out new cert (this takes ~2 minutes)..."
oc rollout status deployment/router-default -n openshift-ingress --timeout=5m

log ""
log "✅  Let's Encrypt certificates applied successfully"
log "    API:    https://${API_DOMAIN}:6443"
log "    Console: https://console-openshift-console.${APPS_DOMAIN}"
log ""
log "Certificates expire in 90 days. Add a weekly cron job to auto-renew:"
log "  0 3 * * 0 $0 --cluster-name ${CLUSTER_NAME} --base-domain ${BASE_DOMAIN} --email ${EMAIL}"
