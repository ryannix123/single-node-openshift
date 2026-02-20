# Free TLS Certificates with Let's Encrypt + Cloudflare

Replace OpenShift's self-signed certificates with real Let's Encrypt wildcard certs. No more browser warnings, and fully automated renewal using the Cloudflare DNS plugin — no manual TXT records required.

---

## Prerequisites

- Your domain's DNS is managed by Cloudflare
- `certbot` installed: `pip install certbot certbot-dns-cloudflare`
- A Cloudflare API token with **Zone:DNS:Edit** permission (see below)
- `oc` CLI configured and pointing at your SNO cluster

---

## Step 1 — Create a Cloudflare API Token

1. Go to [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Click **Create Token**
3. Use the **Edit zone DNS** template
4. Under **Zone Resources**, scope it to your specific zone (e.g. `openshifthelp.com`)
5. Click **Continue to Summary** → **Create Token**
6. Copy the token — you won't see it again

> Scoping the token to a single zone follows least-privilege best practice. If the token is ever compromised, it can only affect DNS for that one domain.

---

## Step 2 — Set Your API Token

Export the token as an environment variable. Add this to your `~/.zshrc` or `~/.bashrc` to make it permanent:

```bash
export CLOUDFLARE_API_TOKEN=your_token_here
```

---

## Step 3 — Run the Playbook

```bash
ansible-playbook letsencrypt.yml
```

The playbook will:

1. Install the `certbot-dns-cloudflare` plugin if not already present
2. Write a temporary `cloudflare.ini` credentials file (mode `0600`)
3. Run certbot — it automatically creates and removes the `_acme-challenge` TXT record via the Cloudflare API
4. Create a ConfigMap with the CA bundle in `openshift-config`
5. Patch the cluster proxy to trust the Let's Encrypt CA
6. Create a TLS secret in `openshift-ingress`
7. Patch the ingress controller to use the new certificate
8. Wait for the ingress controller rollout to complete
9. Verify the certificate on your console endpoint

**Override defaults** if needed:

```bash
ansible-playbook letsencrypt.yml \
  -e ingress_domain=apps.sno.example.com \
  -e certbot_email=you@example.com \
  -e cloudflare_api_token=your_token
```

---

## Renewal

Certificates expire every 90 days. The playbook is idempotent — it checks whether your cert is valid for more than 30 days before running certbot. Just re-run it on a schedule:

```bash
# Add to crontab — runs monthly
0 3 1 * * cd /path/to/single-node-openshift && \
  CLOUDFLARE_API_TOKEN=your_token ansible-playbook letsencrypt.yml
```

Or run it manually whenever you get the Let's Encrypt expiry warning email (sent at 30 and 7 days before expiry).

---

## How It Works

The `certbot-dns-cloudflare` plugin handles the DNS-01 ACME challenge automatically:

1. Certbot asks Let's Encrypt to issue a wildcard cert for `*.apps.sno.openshifthelp.com`
2. Let's Encrypt requires proof you control the domain via a `_acme-challenge` TXT record
3. The Cloudflare plugin creates that TXT record via the API, waits 30 seconds for propagation, and Let's Encrypt verifies it
4. The plugin deletes the TXT record automatically after verification
5. Certbot writes the signed certificate to `~/letsencrypt-sno/live/`

The whole process takes about 60 seconds and requires zero manual steps.

---

## Verify the Certificate

After the playbook completes, confirm the new cert is live:

```bash
echo | openssl s_client \
  -connect console-openshift-console.apps.sno.openshifthelp.com:443 \
  -servername console-openshift-console.apps.sno.openshifthelp.com \
  2>/dev/null | openssl x509 -noout -issuer -dates
```

You should see:
```
issuer=C=US, O=Let's Encrypt, CN=R11
notAfter=May 20 00:00:00 2026 GMT
```

---

## Next Step

➡️ [Optional add-on operators](03-optional-operators.md)
