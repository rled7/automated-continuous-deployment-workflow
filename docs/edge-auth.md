# Edge Authentication: Dex OIDC + oauth2-proxy

> Build 024 — added to the production-readiness extension stack.

## Why edge auth?

Without an edge authentication layer every protected service (app, Argo CD UI, Grafana) must implement its own login flow — duplicating session management, token verification, and user management. Edge auth centralises all of that into a single pass/fail decision at the ingress tier:

- **One login prompt** for all protected services — no per-app auth code.
- **OIDC-standard tokens** — works with any identity provider (static users, GitHub, Google, Okta, Azure AD) by swapping the Dex connector.
- **Zero changes to application code** — the backend receives forwarded headers (`X-Auth-Request-User`, `X-Auth-Request-Email`, `Authorization`) and can trust them.
- **Auditable** — all authentication events flow through Dex logs.

---

## Component architecture

```
User (browser)
  │
  │  HTTPS request to app.127.0.0.1.nip.io
  ▼
ingress-nginx
  │
  │  nginx auth_request subrequest
  │  → GET https://oauth2-proxy.127.0.0.1.nip.io/oauth2/auth
  ▼
oauth2-proxy
  │
  ├─ Cookie present and valid?
  │     YES → return 200 → nginx forwards original request to app backend
  │
  └─ No valid cookie → return 401
       │
       │  nginx reads auth-signin annotation
       │  → 302 redirect to oauth2-proxy /oauth2/start?rd=<original URL>
       ▼
oauth2-proxy /oauth2/start
  │
  │  Builds OIDC authorization URL
  │  → 302 redirect to Dex /auth?client_id=oauth2-proxy&...
  ▼
Dex (OIDC provider) — https://auth.127.0.0.1.nip.io
  │
  │  Shows login page (static users in kind; GitHub/Google in cloud)
  │  User submits credentials
  │  Dex issues authorization code
  │  → 302 redirect to oauth2-proxy /oauth2/callback?code=...
  ▼
oauth2-proxy /oauth2/callback
  │
  │  Exchanges code for ID token + access token via Dex token endpoint
  │  Validates ID token signature against Dex JWKS
  │  Sets signed session cookie (domain: .127.0.0.1.nip.io)
  │  → 302 redirect to original URL (rd= parameter)
  ▼
User arrives at app — subsequent requests hit oauth2-proxy auth check,
cookie is valid, nginx receives 200 and proxies traffic to backend.
```

---

## kind: logging in with static demo users

Two users are pre-configured in `argocd/bootstrap/apps/dex.yaml` under `staticPasswords`. Replace the bcrypt hash placeholders with real hashes before deploying:

```bash
# Generate a bcrypt hash for a password (cost 12):
htpasswd -bnBC 12 "" 'your-password-here' | tr -d ':\n'
```

Store the resulting hash in a SealedSecret and mount it into the Dex configuration. **Never commit real password hashes to git.**

| Email       | Role  |
|-------------|-------|
| admin@local | admin |
| dev@local   | developer |

To log in:

1. Navigate to `https://app.127.0.0.1.nip.io` (or any protected URL).
2. You are redirected to `https://auth.127.0.0.1.nip.io` for login.
3. Enter one of the emails above with the password you chose when generating the hash.
4. On success you are redirected back to the original URL.

---

## cloud: swapping to GitHub OAuth (Dex connector)

Replace the empty `connectors: []` in `argocd/bootstrap/apps/dex.yaml` with:

```yaml
connectors:
  - type: github
    id: github
    name: GitHub
    config:
      # Register an OAuth App at https://github.com/settings/developers
      # Authorization callback URL: https://auth.yourdomain.com/callback
      clientID: <GitHub OAuth App Client ID>
      clientSecret: <GitHub OAuth App Client Secret>   # store in SealedSecret
      redirectURI: https://auth.yourdomain.com/callback
      # Optional: restrict to members of a specific org
      orgs:
        - name: your-github-org
      # Optional: restrict to specific teams
      # teams:
      #   - your-github-org:your-team
```

Also update `config.issuer` and all `nip.io` URLs to your real domain. Remove `--ssl-insecure-skip-verify=true` from the oauth2-proxy extraArgs.

---

## Protecting additional Ingresses (Grafana, Argo CD UI)

Add the same three annotations to any Ingress you want to protect. No other changes are needed.

```yaml
annotations:
  nginx.ingress.kubernetes.io/auth-url: "https://oauth2-proxy.127.0.0.1.nip.io/oauth2/auth"
  nginx.ingress.kubernetes.io/auth-signin: "https://oauth2-proxy.127.0.0.1.nip.io/oauth2/start?rd=https://$host$escaped_request_uri"
  nginx.ingress.kubernetes.io/auth-response-headers: "Authorization, X-Auth-Request-User, X-Auth-Request-Email"
```

For Argo CD, if you run the Argo CD server with `--auth-mode=sso`, you can configure Argo CD itself to use Dex as its OIDC provider — then the same Dex instance handles both the edge auth and the Argo CD SSO. See the [Argo CD SSO docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/).

---

## Rotating secrets

### cookieSecret

The `cookieSecret` signs oauth2-proxy session cookies. Rotating it invalidates all active sessions — users will be prompted to log in again.

```bash
# 1. Generate a new 32-byte secret
NEW_SECRET=$(openssl rand -base64 32)

# 2. Seal it
echo -n "$NEW_SECRET" | kubeseal --raw \
  --from-file=/dev/stdin \
  --namespace auth \
  --name oauth2-proxy-secrets

# 3. Update the SealedSecret manifest in git, commit, push.
# 4. Argo CD syncs → oauth2-proxy pod restarts → old sessions invalidated.
```

### clientSecret

The `clientSecret` is shared between Dex (in `staticClients`) and oauth2-proxy (`config.clientSecret`). Both must be updated atomically.

```bash
NEW_SECRET=$(openssl rand -hex 32)

# Seal for Dex (namespace: auth, secret name: dex-client-secrets)
echo -n "$NEW_SECRET" | kubeseal --raw \
  --from-file=/dev/stdin \
  --namespace auth \
  --name dex-client-secrets

# Seal for oauth2-proxy (namespace: auth, secret name: oauth2-proxy-secrets)
echo -n "$NEW_SECRET" | kubeseal --raw \
  --from-file=/dev/stdin \
  --namespace auth \
  --name oauth2-proxy-secrets

# Update both SealedSecret manifests in git in the same commit.
# Argo CD syncs → both pods restart with the new shared secret.
```

---

## Logout

Navigate to:

```
https://oauth2-proxy.127.0.0.1.nip.io/oauth2/sign_out
```

This clears the session cookie. The user is returned to the login page on their next protected request. To also revoke the Dex session (prevent re-auth without re-entering credentials), configure oauth2-proxy with `--oidc-extra-audience` and use Dex's `/token/revocation` endpoint where supported.

---

## Troubleshooting

### Cookie domain mismatches

**Symptom:** Login loop — auth succeeds but the browser is immediately redirected back to login.

**Cause:** The cookie domain set by oauth2-proxy does not match the host the user is visiting.

**Fix:** Ensure `--cookie-domain` and `--whitelist-domain` in the oauth2-proxy extraArgs cover ALL protected hostnames. In this repo both are set to `.127.0.0.1.nip.io` which matches all `*.127.0.0.1.nip.io` subdomains.

### Redirect loops

**Symptom:** Browser shows "Too many redirects" or the request bounces between the app and oauth2-proxy indefinitely.

**Possible causes:**
1. `--reverse-proxy=true` is missing from oauth2-proxy extraArgs. Without it, oauth2-proxy tries to proxy the request itself instead of returning 200/401 for nginx to act on.
2. The `auth-url` annotation points to a URL that is itself protected by auth (circular dependency). oauth2-proxy's own Ingress must NOT have auth annotations.
3. The nginx `auth_request` subrequest returns a redirect (3xx) instead of 200/401. Confirm oauth2-proxy's `/oauth2/auth` endpoint is reachable from within the cluster.

### OIDC issuer URL mismatches

**Symptom:** oauth2-proxy logs `failed to fetch OIDC discovery document` or `token verification failed: issuer mismatch`.

**Cause:** The `--oidc-issuer-url` passed to oauth2-proxy does not exactly match the `issuer` field in Dex's config AND in the OIDC discovery document returned by Dex.

**Fix:**
- Dex `config.issuer` must match `--oidc-issuer-url` in oauth2-proxy character-for-character (including trailing slash).
- In this repo both are `https://auth.127.0.0.1.nip.io` (no trailing slash).
- If Dex is behind TLS with a self-signed cert, `--ssl-insecure-skip-verify=true` must be set in oauth2-proxy (kind only).

### Self-signed certificate warnings

Expected on kind. The browser will show a certificate warning for all `*.127.0.0.1.nip.io` hosts because cert-manager uses the `selfsigned-issuer`. Click through the warning or import the CA into your browser's trust store. Remove `selfsigned-issuer` and switch to `letsencrypt-prod` when deploying to a cloud cluster with real public DNS.
