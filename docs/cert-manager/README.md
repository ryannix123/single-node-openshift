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

> The secret lives in the **`cert-manager`** namespace, not `openshift-ingress`.
> Because these are *Cluster*Issuers, cert-manager reads the token from the
> operator's cluster-resource namespace (`cert-manager`). Don't move it next to
> the Certificate — the DNS-01 solver won't find it there.

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

`READY=False` immediately after apply is **normal** — issuance is a multi-step
chain (Certificate → CertificateRequest → Order → Challenge → present the
`_acme-challenge` TXT record in Cloudflare → wait for DNS propagation → Let's
Encrypt validates → issue) and typically takes 1–3 minutes. Be patient before
calling it stuck.

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
re-apply:

```
oc apply -f 03-wildcard-certificate.yaml
oc get certificate apps-wildcard -n openshift-ingress -w
```

Changing `issuerRef` triggers a fresh prod DNS-01 round. If the secret does
**not** re-issue on its own within a couple of minutes (the issuer check in
[Verify](#verify) still shows staging), force it by deleting the secret so
cert-manager regenerates it from the current issuer:

```
oc delete secret letsencrypt-wildcard -n openshift-ingress
```

> **Order matters:** the delete-secret trick only re-mints from whatever
> `issuerRef` currently points at. Delete the secret *before* flipping to prod
> and you just get another staging cert. Flip first, then force.

### 6. Point the ingress controller at the secret (one time)

**Do not run this until the issuer check in [Verify](#verify) shows a real
production issuer** — patching the router while still on staging makes your
console serve an untrusted cert to everyone.

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

### Confirm you're on production, not staging

Check the issuer on the secret itself **before** patching the router (step 6):

```
oc get secret letsencrypt-wildcard -n openshift-ingress \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer
```

Production reads `O=Let's Encrypt` with a real intermediate CN and **no**
"(STAGING)". As of Let's Encrypt's 2026 "Generation Y" rollout that CN is `YR1`
(RSA) — unfamiliar, but correct. Staging reads something like
`CN=(STAGING) Dastardly Durum YR1`. **If you see "(STAGING)", stop — do not
patch the router.**

### Confirm the trust chain

```
echo | openssl s_client \
  -connect console-openshift-console.apps.sno.openshifthelp.com:443 \
  -servername console-openshift-console.apps.sno.openshifthelp.com 2>/dev/null \
  | openssl x509 -noout -issuer -enddate
```

You should see a Let's Encrypt issuer and an expiry ~90 days out. For a clean
`Verify return code: 0 (ok)` and the full chain (leaf → intermediate → root):

```
echo | openssl s_client \
  -connect console-openshift-console.apps.sno.openshifthelp.com:443 \
  -servername console-openshift-console.apps.sno.openshifthelp.com 2>/dev/null \
  | grep -i "verify return code"

oc get secret letsencrypt-wildcard -n openshift-ingress -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl crl2pkcs7 -nocrl -certfile /dev/stdin \
  | openssl pkcs7 -print_certs -noout | grep -E "subject=|issuer="
```

On the current Generation Y hierarchy the chain terminates as
`YR1 → Root YR → (cross-signed by) ISRG Root X1`. That cross-sign to the
long-trusted `ISRG Root X1` is what keeps you trusted on today's browsers and
operating systems — exactly what you want. Reload the console; the padlock
should be clean.

## Renewal

Nothing to do. cert-manager reissues at ~day 60 and rotates the
`letsencrypt-wildcard` secret in place; the router reloads on the secret change.
To confirm health at any time:

```
oc get certificate apps-wildcard -n openshift-ingress
```

`READY=True` with a `NOT AFTER` date in the future means you're covered.

## Gotchas

Hard-won notes from real runs — skim these before you start.

- **Be patient — `READY=False` is not failure.** DNS-01 issuance is a chain of
  objects and a DNS round-trip; 1–3 minutes is normal, and the first run can be
  slower. Don't start deleting things at 30 seconds.

- **Verify the issuer before you patch the router.** The step-6 patch makes the
  router serve whatever is in `letsencrypt-wildcard`. If that's still a *staging*
  cert, every user gets an untrusted-cert warning. Always run the issuer
  one-liner in [Verify](#verify) first — you want no "(STAGING)" in the CN.

- **Flip to prod *before* forcing a reissue.** Deleting the secret only re-mints
  from the Certificate's current `issuerRef`. Delete while still on staging and
  you get another staging cert (this is the #1 way people spin their wheels).
  Order: change `issuerRef` → `letsencrypt-prod`, apply, *then* delete the secret
  if it doesn't reissue on its own.

- **`issuerRef` change doesn't always auto-reissue.** cert-manager *should*
  reissue when you flip the issuer, but if the secret still shows the old issuer
  after a couple minutes, the reliable force is
  `oc delete secret letsencrypt-wildcard -n openshift-ingress` — it regenerates
  from the current issuer.

- **The Cloudflare token secret goes in `cert-manager`, not `openshift-ingress`.**
  ClusterIssuers read `apiTokenSecretRef` from the operator's cluster-resource
  namespace. Putting it next to the Certificate is a common and silent mistake.

- **Never paste or commit the API token.** If it's ever exposed (a shell paste, a
  screen share, a commit), treat it as compromised: roll it in Cloudflare and
  swap it in place — cert-manager re-reads it automatically:

  ```
  oc create secret generic cloudflare-api-token \
    --from-literal=api-token=NEW_TOKEN \
    -n cert-manager --dry-run=client -o yaml | oc replace -f -
  ```

- **A hung challenge is almost always egress or DNS.** The controller needs
  outbound to `acme-v02.api.letsencrypt.org` and `api.cloudflare.com`, and Let's
  Encrypt validates the TXT record against **public** DNS. Debug with:

  ```
  oc describe challenge -n openshift-ingress
  oc -n cert-manager logs -l app.kubernetes.io/name=cert-manager --tail=50
  ```

  The challenge detail tells you whether it's stuck *presenting* the record
  (token scope / zone) or *waiting on propagation* (harmless — just wait).

- **`YR1` / "Generation Y" is expected, not a bug.** Since the 2026 rollout, the
  prod intermediate CN is `YR1` and the leaf chains via `Root YR`, cross-signed
  by `ISRG Root X1`. If you were used to seeing `R10`/`R11`, the new CN can look
  wrong — it isn't. Confirm with a `Verify return code: 0 (ok)`.

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