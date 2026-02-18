# Free TLS Certificates with Let's Encrypt

Replace OpenShift's self-signed certificates with real Let's Encrypt certs. No more browser warnings.

---

## Prerequisites

- Your cluster's API and wildcard ingress are reachable from the internet **or** you're using a DNS-01 challenge provider
- `certbot` installed on the machine where you'll run the scripts

---

## Step 1 — Obtain Certificates

Use the `renew-letsencrypt.sh` script in the `scripts/` directory:

```bash
./scripts/renew-letsencrypt.sh \
  --cluster-name sno \
  --base-domain example.com \
  --email you@example.com
```

The script uses an HTTP-01 challenge by default. If your cluster isn't internet-accessible, switch to a DNS-01 challenge by setting your DNS provider credentials before running.

---

## Step 2 — Apply the Manifests

```bash
oc apply -f manifests/tls/
```

This patches both the **API server** and **ingress controller** to use the new certificates.

---

## Step 3 — Verify

```bash
# Check the ingress cert
echo | openssl s_client -connect console-openshift-console.apps.sno.example.com:443 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

You should see `issuer= /C=US/O=Let's Encrypt`.

---

## Renewal

Certificates expire every 90 days. Automate renewal with a cron job:

```bash
# Run renewal check weekly
0 3 * * 0 /path/to/single-node-openshift/scripts/renew-letsencrypt.sh \
  --cluster-name sno --base-domain example.com --email you@example.com
```

Or use the safe-shutdown script before any planned downtime — it handles cert rotation automatically.

---

## Next Step

➡️ [Optional add-on operators](03-optional-operators.md)
