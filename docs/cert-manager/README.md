# Automated Wildcard TLS for SNO with cert-manager

Author: Ryan Nix <ryan.nix@gmail.com>
Repo: https://github.com/ryannix123/single-node-openshift

This replaces the old certbot-driven `letsencrypt.yml` playbook. Instead of
obtaining the cert on your workstation and re-running a playbook every 90 days,
the **cert-manager Operator for Red Hat OpenShift** obtains and renews the
wildcard cert *inside the cluster*. Nothing is stored on your Mac, and there is
no quarterly re-run — cert-manager rotates the cert automatically at ~day 60 of
its 90-day lifetime.

## What you get

- Wildcard cert `*.apps.sno.openshifthelp.com` from Let's Encrypt
- DNS-01 challenge solved automatically through Cloudflare
- Automatic renewal, in-place secret rotation, router picks it up on its own
- The OpenShift console cert is covered, since it's served through the router

## Prerequisites

- SNO cluster reachable, `oc` logged in as cluster-admin (kubeadmin is fine)
- A Cloudflare API token scoped to the `openshifthelp.com` zone with
  `Zone:DNS:Edit` (+ `Zone:Zone:Read`). Create at
  https://dash.cloudflare.com/profile/api-tokens using the "Edit zone DNS"
  template.
- cert-manager's controller pod needs outbound access to the Let's Encrypt and
  Cloudflare APIs. On this SNO behind a proxy, the Red Hat operator honors the
  cluster-wide proxy config automatically — no extra step unless you've done
  something custom to egress.

## Files

| File | Purpose |
|------|---------|
| `00-operator-subscription.yaml` | Installs the Red Hat cert-manager operator via OLM |
| `01-cloudflare-secret.yaml` | Cloudflare API token secret (do not commit the real token) |
| `02-clusterissuers.yaml` | Let's Encrypt staging + prod ClusterIssuers |
| `03-wildcard-certificate.yaml` | The `*.apps` wildcard Certificate request |

## Install

### 1. Install the operator

```
oc apply -f 00-operator-subscription.yaml
oc get csv -n cert-manager-operator -w
```

Wait until the CSV phase is `Succeeded`, then confirm the controller pods are
running:

```
oc get pods -n cert-manager
```

### 2. Create the Cloudflare token secret

Do **not** commit your real token. Either edit `01-cloudflare-secret.yaml`
locally and keep it out of git, or create it imperatively:

```
oc create secret generic cloudflare-api-token \
  --from-literal=api-token=YOUR_TOKEN_HERE \
  -n cert-manager
```

### 3. Create the issuers

```
oc apply -f 02-clusterissuers.yaml
```

### 4. Request the cert — staging first

`03-wildcard-certificate.yaml` ships pointed at **staging** on purpose. Apply
it and watch the cert reach Ready:

```
oc apply -f 03-wildcard-certificate.yaml
oc get certificate apps-wildcard -n openshift-ingress -w
```

Staging issues an *untrusted* cert, so your browser will still complain — that
is expected. You're only proving the Cloudflare DNS-01 solver works before
touching production rate limits. If it stalls, check:

```
oc describe certificate apps-wildcard -n openshift-ingress
oc describe challenge -n openshift-ingress
```

### 5. Flip to production

Once staging shows `READY=True`, edit `03-wildcard-certificate.yaml` and change
`issuerRef.name` from `letsencrypt-staging` to `letsencrypt-prod`, then
re-apply. cert-manager issues a fresh trusted cert automatically:

```
oc apply -f 03-wildcard-certificate.yaml
oc get certificate apps-wildcard -n openshift-ingress -w
```

### 6. Point the ingress controller at the secret (one time)

```
oc patch ingresscontroller.operator default \
  --type=merge \
  --patch '{"spec":{"defaultCertificate":{"name":"letsencrypt-wildcard"}}}' \
  -n openshift-ingress-operator
```

The router rolls automatically. Watch it:

```
oc rollout status deployment/router-default -n openshift-ingress
```

That's the last manual step, ever. From here cert-manager renews on its own.

## Verify

```
echo | openssl s_client \
  -connect console-openshift-console.apps.sno.openshifthelp.com:443 \
  -servername console-openshift-console.apps.sno.openshifthelp.com 2>/dev/null \
  | openssl x509 -noout -issuer -enddate
```

You should see a Let's Encrypt issuer and an expiry ~90 days out. Reload the
console in your browser — the padlock should be clean.

## Renewal

Nothing to do. cert-manager reissues at ~day 60 and rotates the
`letsencrypt-wildcard` secret in place; the router reloads on the secret change.
To confirm health at any time:

```
oc get certificate apps-wildcard -n openshift-ingress
```

`READY=True` with a `NOT AFTER` date in the future means you're covered.

## Notes vs. the old certbot playbook

- The old `proxy/cluster` `trustedCA` step is **gone**. Let's Encrypt chains to
  ISRG Root X1, already in the system trust store, so trusting it for egress was
  a no-op for serving the ingress cert.
- Date-stamped resource names (`letsencrypt-ca-072026`) are **gone**.
  cert-manager owns one stable secret and rotates it in place.
- The API server cert (`api.sno...`) is a separate endpoint, not covered by the
  `*.apps` wildcard. It's managed by OpenShift's own rotation by default. If you
  ever install a custom serving cert there, it would be a second `Certificate`
  object targeting `openshift-config` — out of scope here.
