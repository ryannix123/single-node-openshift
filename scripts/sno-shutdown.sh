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