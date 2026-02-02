#!/bin/bash
#
# renew-letsencrypt.sh - Renew Let's Encrypt certificates and update OpenShift
# Author: Ryan Nix <ryan.nix@gmail.com>
#
# Prerequisites:
#   - certbot installed
#   - Initial certificate already generated
#   - oc CLI authenticated to the cluster
#
# Usage: ./renew-letsencrypt.sh [options]
#

set -euo pipefail

# Configuration - adjust these for your environment
CERT_DIR="${CERT_DIR:-$HOME/letsencrypt-sno}"
DOMAIN="${DOMAIN:-apps.sno.openshifthelp.com}"
CERT_SUFFIX=$(date +%m%d%y)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Renew Let's Encrypt certificates and update OpenShift ingress.

Options:
    -d, --domain DOMAIN     Domain name (default: apps.sno.openshifthelp.com)
    -c, --cert-dir DIR      Certificate directory (default: ~/letsencrypt-sno)
    -f, --force             Force renewal even if not needed
    -h, --help              Show this help message

Environment Variables:
    CERT_DIR    Same as --cert-dir
    DOMAIN      Same as --domain

Examples:
    $(basename "$0")
    $(basename "$0") --domain apps.sno.example.com
    $(basename "$0") --force

EOF
}

FORCE_RENEWAL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -c|--cert-dir)
            CERT_DIR="$2"
            shift 2
            ;;
        -f|--force)
            FORCE_RENEWAL=true
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

LIVE_DIR="${CERT_DIR}/live/${DOMAIN}"

# Check prerequisites
if ! command -v certbot &> /dev/null; then
    log_error "certbot not found. Please install certbot."
    exit 1
fi

if ! command -v oc &> /dev/null; then
    log_error "oc not found. Please install the OpenShift CLI."
    exit 1
fi

if ! oc whoami &> /dev/null; then
    log_error "Not logged into OpenShift cluster."
    exit 1
fi

if [[ ! -d "$LIVE_DIR" ]]; then
    log_error "Certificate directory not found: $LIVE_DIR"
    log_error "Generate initial certificate first with:"
    echo "  certbot certonly --manual --preferred-challenges dns -d '*.${DOMAIN}' \\"
    echo "    --config-dir ${CERT_DIR} --work-dir ${CERT_DIR} --logs-dir ${CERT_DIR}"
    exit 1
fi

log_info "Certificate renewal for *.${DOMAIN}"
log_info "Certificate directory: ${CERT_DIR}"
log_info "Suffix for this renewal: ${CERT_SUFFIX}"
echo ""

# Check current certificate expiration
EXPIRY=$(openssl x509 -in "${LIVE_DIR}/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
NOW_EPOCH=$(date +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

log_info "Current certificate expires: $EXPIRY ($DAYS_LEFT days remaining)"

# Renew if needed
if [[ $DAYS_LEFT -le 30 ]] || [[ "$FORCE_RENEWAL" == "true" ]]; then
    if [[ "$FORCE_RENEWAL" == "true" ]]; then
        log_info "Forcing certificate renewal..."
    else
        log_info "Certificate expires soon, renewing..."
    fi
    
    certbot renew \
        --config-dir "$CERT_DIR" \
        --work-dir "$CERT_DIR" \
        --logs-dir "$CERT_DIR"
    
    log_info "Certificate renewed successfully"
else
    log_info "Certificate still valid for $DAYS_LEFT days, no renewal needed"
    log_info "Use --force to renew anyway"
fi

echo ""
log_info "Updating OpenShift configuration..."

# Create/update the TLS secret
log_info "Creating TLS secret: letsencrypt-tls-${CERT_SUFFIX}"
oc create secret tls "letsencrypt-tls-${CERT_SUFFIX}" \
    --cert="${LIVE_DIR}/fullchain.pem" \
    --key="${LIVE_DIR}/privkey.pem" \
    -n openshift-ingress \
    --dry-run=client -o yaml | oc apply -f -

# Create/update the CA ConfigMap
log_info "Creating CA ConfigMap: letsencrypt-ca-${CERT_SUFFIX}"
oc create configmap "letsencrypt-ca-${CERT_SUFFIX}" \
    --from-file=ca-bundle.crt="${LIVE_DIR}/fullchain.pem" \
    -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -

# Update proxy trust
log_info "Updating proxy CA trust..."
oc patch proxy/cluster \
    --type=merge \
    --patch="{\"spec\":{\"trustedCA\":{\"name\":\"letsencrypt-ca-${CERT_SUFFIX}\"}}}"

# Update ingress controller
log_info "Updating ingress controller certificate..."
oc patch ingresscontroller.operator default \
    --type=merge \
    -p "{\"spec\":{\"defaultCertificate\":{\"name\":\"letsencrypt-tls-${CERT_SUFFIX}\"}}}" \
    -n openshift-ingress-operator

echo ""
log_info "Waiting for router pods to restart..."
sleep 5

# Wait for router pods to be ready
oc rollout status deployment/router-default -n openshift-ingress --timeout=120s || true

echo ""
log_info "Verifying certificate..."
sleep 5

# Verify the new certificate is in use
ISSUER=$(echo | timeout 10 openssl s_client -connect "console-openshift-console.${DOMAIN}:443" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || echo "unknown")
log_info "Certificate issuer: $ISSUER"

echo ""
log_info "Certificate renewal complete!"
log_info ""
log_info "Old secrets/configmaps can be cleaned up manually:"
log_info "  oc get secrets -n openshift-ingress | grep letsencrypt"
log_info "  oc get configmaps -n openshift-config | grep letsencrypt"
