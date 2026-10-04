#!/bin/bash
# sno-csr-autoapprove.sh — runs ON the node, as root, at boot.
#
# Approves this node's own kubelet certificate requests for the first hour
# after boot, so a homelab SNO that was powered off past its kubelet
# certificate's expiry rejoins without anyone SSHing in.
#
# HOMELAB ONLY. OpenShift refuses to do this by design: on a platform-none
# cluster there is no Machine object to prove a returning node is who it says
# it is, so a CSR from the bootstrapper looks exactly like a stranger asking to
# join. On a single node you own, that stranger can only be the node itself.
# On anything multi-node or production, do not install this.
#
# Delivered by manifests/99-master-sno-csr-autoapprove.yaml. Logs to the
# journal:  journalctl -u sno-csr-autoapprove

set -uo pipefail

export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
WINDOW_MIN="${WINDOW_MIN:-60}"
BOOTSTRAPPER="system:serviceaccount:openshift-machine-config-operator:node-bootstrapper"
SHORT="system:node:$(hostname -s)"
FULL="system:node:$(hostname -f 2>/dev/null || hostname)"

log() { echo "sno-csr-autoapprove: $*"; }

command -v oc >/dev/null || { log "oc not found on this node — nothing to do"; exit 0; }

pending_mine() {
  oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}} {{.spec.signerName}} {{.spec.username}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
  | awk -v boot="$BOOTSTRAPPER" -v s="$SHORT" -v f="$FULL" '
      $2=="kubernetes.io/kube-apiserver-client-kubelet" && ($3==boot || $3==s || $3==f) { print $1; next }
      $2=="kubernetes.io/kubelet-serving"               && ($3==s || $3==f)             { print $1 }'
}

DEADLINE=$(( $(date +%s) + WINDOW_MIN * 60 ))
log "watching for this node's kubelet CSRs for ${WINDOW_MIN} min (${SHORT})"

APPROVED=0
while (( $(date +%s) < DEADLINE )); do
  # The API comes and goes for a while after a long shutdown as operators roll
  # new revisions. Just wait for it.
  if ! oc get --raw /readyz >/dev/null 2>&1; then
    sleep 15
    continue
  fi
  for csr in $(pending_mine); do
    if oc adm certificate approve "$csr" >/dev/null 2>&1; then
      log "approved ${csr}"
      APPROVED=$((APPROVED + 1))
    fi
  done
  sleep 30
done

log "window closed — approved ${APPROVED} CSR(s)"
