#!/usr/bin/env bash
# sno-shutdown.sh — shut down a Single Node OpenShift cluster cleanly, and tell
# you how long it can stay off before a restart needs a human.
#
# Usage:  ./scripts/sno-shutdown.sh            # interactive confirm
#         ./scripts/sno-shutdown.sh --yes      # no prompt
#         DELAY_MIN=5 ./scripts/sno-shutdown.sh
#
# What this script cannot do is make certificates last longer. The kubelet's
# client certificate is capped by the cluster's CSR signer, roughly 30 days,
# however recently it rotated. Power on after the date this script prints and
# the kubelet comes back asking for CSR approval. Either approve them by hand
# (see README → "Coming back after a long shutdown"), or install
# manifests/99-master-sno-csr-autoapprove.yaml once and it happens on boot.

set -euo pipefail

DELAY_MIN="${DELAY_MIN:-1}"
ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

REPORT="${HOME}/.sno-last-shutdown"
BOOTSTRAPPER="system:serviceaccount:openshift-machine-config-operator:node-bootstrapper"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\033[31mfail\033[0m %s\n' "$*" >&2; exit 1; }

# Portable date → epoch (GNU date on Linux, BSD date on macOS).
to_epoch() {
  local d; d=$(echo "$1" | tr -s ' ')
  date -u -d "$d" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$d" +%s 2>/dev/null \
    || date -u -j -f '%b %d %H:%M:%S %Y %Z' "$d" +%s 2>/dev/null \
    || echo ""
}
days_until() {
  local e; e=$(to_epoch "$1")
  [[ -n "$e" ]] && echo $(( (e - $(date -u +%s)) / 86400 )) || echo "?"
}

# Pending CSRs that are this cluster's own kubelets — and nothing else.
# Never blanket-approve: a CSR is a request for an identity.
pending_kubelet_csrs() {
  oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}} {{.spec.signerName}} {{.spec.username}}{{"\n"}}{{end}}{{end}}' \
  | awk -v boot="$BOOTSTRAPPER" '
      $2=="kubernetes.io/kube-apiserver-client-kubelet" && ($3==boot || $3 ~ /^system:node:/) { print $1; next }
      $2=="kubernetes.io/kubelet-serving"               &&  $3 ~ /^system:node:/             { print $1 }'
}
pending_other_csrs() {
  oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
  | grep -vxF -f <(pending_kubelet_csrs; echo __none__) || true
}

# ── 0. Who are we talking to ─────────────────────────────────────────────────
command -v oc >/dev/null || die "oc not found in PATH"
oc whoami >/dev/null 2>&1 || die "not logged in — oc login first (KUBECONFIG=${KUBECONFIG:-~/.kube/config})"

SERVER=$(oc whoami --show-server)
NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
say "Cluster: ${SERVER}"
say "Nodes:   ${NODES}"

# ── 1. Pre-flight ────────────────────────────────────────────────────────────
say "Pre-flight"

# Red Hat's guidance: do not shut down inside the first 24 hours. The
# bootstrap certificates rotate at ~24h; power off before that and the
# cluster may not come back at all.
CREATED=$(oc get clusterversion version -o jsonpath='{.metadata.creationTimestamp}')
CREATED_E=$(to_epoch "$CREATED")
if [[ -n "$CREATED_E" ]] && (( $(date -u +%s) - CREATED_E < 86400 )); then
  die "cluster is less than 24h old (installed ${CREATED}). Wait for the first certificate rotation."
fi
ok "cluster age > 24h (installed ${CREATED})"

UNHEALTHY=$(oc get co --no-headers | awk '$3!="True" || $5!="False" {print $1}' | tr '\n' ' ')
if [[ -n "$UNHEALTHY" ]]; then
  warn "operators not healthy: ${UNHEALTHY}— shutting down mid-rollout is how you get a bad morning"
else
  ok "all cluster operators Available and not Degraded"
fi

# ── 2. Clear any pending kubelet CSRs ────────────────────────────────────────
# A renewal that is still Pending at shutdown is a renewal you will be
# approving by hand at boot. Approve, wait for the follow-on serving CSR,
# approve again.
say "Kubelet certificate requests"
for _ in 1 2 3; do
  CSRS=$(pending_kubelet_csrs)
  [[ -z "$CSRS" ]] && break
  for c in $CSRS; do oc adm certificate approve "$c" >/dev/null && ok "approved ${c}"; done
  sleep 20
done
[[ -z "$(pending_kubelet_csrs)" ]] && ok "no kubelet CSRs pending"
OTHER=$(pending_other_csrs | tr '\n' ' ')
[[ -n "$OTHER" ]] && warn "other pending CSRs left alone (not kubelet): ${OTHER}"

# ── 3. How long can it stay off? ─────────────────────────────────────────────
say "Certificate deadlines"

# The soft deadline: the kubelet client certificate. Power on before this and
# the node rejoins with no human involved. After it, approve CSRs on boot.
SOFT=""
for node in $NODES; do
  END=$(oc debug "node/${node}" -q -- chroot /host \
          openssl x509 -enddate -noout -in /var/lib/kubelet/pki/kubelet-client-current.pem 2>/dev/null \
        | sed -n 's/^notAfter=//p' || true)
  if [[ -n "$END" ]]; then
    echo "     ${node}: kubelet client cert expires ${END}  ($(days_until "$END") days)"
    SOFT="${SOFT:-$END}"
  else
    warn "${node}: could not read the kubelet client certificate"
  fi
done

# The hard deadline: Red Hat's documented outer limit for a graceful restart.
HARD=$(oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer \
         -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}' 2>/dev/null || true)

echo
if [[ -n "$SOFT" ]]; then
  printf '     \033[1mNo-touch restart:\033[0m power on before %s (%s days)\n' "$SOFT" "$(days_until "$SOFT")"
  echo "                       after that, approve kubelet CSRs on first boot"
fi
if [[ -n "$HARD" ]]; then
  printf '     \033[1mHard limit:\033[0m       %s (%s days) — Red Hat'"'"'s outer limit for a graceful restart\n' \
    "$HARD" "$(days_until "$HARD")"
fi

{
  echo "cluster:          ${SERVER}"
  echo "shut down:        $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "no-touch restart: ${SOFT:-unknown}"
  echo "hard limit:       ${HARD:-unknown}"
} > "$REPORT"
echo "     (saved to ${REPORT} — read it when you come back)"
echo

# ── 4. Shut down ─────────────────────────────────────────────────────────────
if (( ! ASSUME_YES )); then
  read -r -p "Shut down ${SERVER} in ${DELAY_MIN} min? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

for node in $NODES; do
  say "Scheduling shutdown of ${node} in ${DELAY_MIN} min"
  oc debug "node/${node}" -q -- chroot /host shutdown -h "${DELAY_MIN}"
done
ok "done — the node powers off in ${DELAY_MIN} min"
