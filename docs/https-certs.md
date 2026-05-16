# HTTPS certificate workflows

Webtrees' in-container nginx listens on port 80 only. TLS termination
is delegated to a reverse proxy in front of the stack — a deliberate
split that keeps cert renewal, OCSP stapling, and DNS-01 plumbing out
of the app container, at the cost of requiring operators to run a
separate proxy. The two workflows below cover the operator's
realistic choices: Traefik with an ACME resolver, and a host-level
proxy (nginx, Caddy, HAProxy, cloud LB) that does its own cert
management.

For the env-var that flips the inside-the-stack HTTPS redirect, see
[`customizing.md` → Switching HTTPS on or off after install](customizing.md#switching-https-on-or-off-after-install).

## Workflow 1: Traefik + ACME

The wizard's `--proxy traefik` mode (see [`proxy-traefik.md`](proxy-traefik.md))
renders compose labels — `traefik.enable=true`,
`traefik.http.routers.webtrees.rule=Host(...)`,
`traefik.http.routers.webtrees.entrypoints=websecure`,
`traefik.http.routers.webtrees.tls=true` — and joins the stack to an
external `traefik` Docker network. Cert resolution is entirely the
Traefik instance's job: the wizard does not render a
`tls.certresolver` label, so Traefik selects the cert via its
default resolver, file-provider store, or whatever is configured at
the Traefik level.

### Prerequisites

| Requirement | Why |
|---|---|
| Public DNS for the configured hostname pointing at the Traefik host | ACME's HTTP-01 / TLS-ALPN challenge needs the issuer to reach Traefik on :80 / :443. |
| Traefik's `entryPoints.websecure` published on :443 with TLS enabled | The wizard's labels assume this entrypoint name. |
| A default `certificatesResolver` in Traefik's static config | The wizard does not name a resolver — Traefik must have one set as default, or attach one via dynamic config. |
| Outbound :443 from the Traefik host to the ACME issuer's directory | Cert registration + challenge responses. |

### Install

```bash
./install --proxy traefik --domain webtrees.example.org
```

The first `docker compose up -d` triggers Traefik to request the cert.
The first browser hit serves it.

### Renewal

Traefik renews certs automatically on its own timer. No operator
action required. The cert lives in Traefik's resolver storage (e.g.
`acme.json`), not in the webtrees stack — backups of webtrees do not
need to include it.

### Troubleshooting

- **`Bad Gateway` from Traefik**: webtrees container isn't healthy
  yet. `make logs` surfaces the entrypoint's status banner.
- **Wrong cert served (staging instead of production, or unexpected
  cert):** Traefik's resolver selection lies outside this stack —
  inspect `docker logs traefik` for which resolver / store handed
  back the cert and adjust at the Traefik level. Common cause: a
  staging `caServer` left in the ACME resolver block from initial
  setup; a file-provider cert masking the ACME path; or no resolver
  configured at all.
- **`ERR_TOO_MANY_REDIRECTS`**: the in-container trust gate refused
  `X-Forwarded-Proto: https` from Traefik because Traefik runs on a
  Docker network outside the trusted CIDR set. Set
  `NGINX_TRUSTED_PROXIES=<your-cidr>` — see
  [`customizing.md` → HTTPS trust gate](customizing.md#https-trust-gate).

## Workflow 2: Host-level reverse proxy

When you terminate TLS at a host-level nginx, Caddy, HAProxy, or a
cloud LB, the wizard's `--proxy standalone` mode publishes a
plain-HTTP port the existing proxy targets. The cert lives on the
proxy — either pre-issued (bring-your-own) or auto-provisioned by
Caddy / certbot. Whichever way the cert is sourced, the in-container
trust gate notes after the example snippets apply.

### Install

```bash
./install --proxy standalone --port 28080
```

Then configure your host proxy. Example for nginx on the host
terminating TLS:

```nginx
server {
    listen 443 ssl http2;
    server_name webtrees.example.org;

    ssl_certificate     /etc/letsencrypt/live/webtrees.example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/webtrees.example.org/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:28080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

The `X-Forwarded-Proto: https` header tells the in-container nginx to
skip its enforce-https 301 redirect — but only when the source IP
falls inside the trust gate's accepted CIDR set. A host proxy
reaching webtrees via `127.0.0.1:<APP_PORT>` is in the set whichever
Docker `userland-proxy` mode is active: with `userland-proxy=true`
(the dockerd binary default), the userspace `docker-proxy` SNATs
the source to the bridge gateway (e.g. `172.17.0.1`); with
`userland-proxy=false`, iptables DNAT preserves the source as the
host loopback (`127.0.0.1`). Both `172.16.0.0/12` and `127.0.0.0/8`
are in the default trusted set.

The case that does need manual intervention is when the proxy lives
on a custom compose network with a subnet outside `172.16.0.0/12`,
on a Docker Swarm overlay, on a Kubernetes pod network, or reaches
the container via a non-loopback host IP — in those setups add the
proxy's CIDR via `NGINX_TRUSTED_PROXIES`. See
[`customizing.md` → HTTPS trust gate](customizing.md#https-trust-gate)
for the authoritative CIDR list and the security trade-off attached
to `userland-proxy=true` (any sibling container can spoof the header
because the trust gate cannot distinguish a legitimate forward from
a SNATed external request).

Caddy v2 equivalent (auto-provisions Let's Encrypt and renews
internally):

```caddyfile
webtrees.example.org {
    reverse_proxy 127.0.0.1:28080 {
        header_up X-Forwarded-Proto https
    }
}
```

### Renewal

- **Host nginx + certbot**: operator-owned. After certbot's hook
  rewrites `fullchain.pem`, run `nginx -s reload` on the host (not
  inside the container). Webtrees' in-container nginx never sees the
  cert, so no container restart is needed.
- **Caddy**: handles renewal internally; no operator action.

## Self-signed certificate (homelab / internal CA)

For LAN, internal-CA-issued, or otherwise non-public hostnames where
ACME isn't an option, the stack still slots into the two workflows
above — only the cert source changes. Pick the pattern that matches
the proxy you already run, or want to run.

### Pattern A: Traefik + file-provider cert

The wizard renders only `traefik.http.routers.webtrees.tls: "true"`,
so a cert supplied via Traefik's file provider satisfies that label
without any ACME involvement.

1. Drop the cert + key on the Traefik host and reference them from
   Traefik's dynamic config (e.g. `/etc/traefik/dynamic/certs.yml`):

   ```yaml
   tls:
       certificates:
           - certFile: /etc/traefik/certs/webtrees.crt
             keyFile: /etc/traefik/certs/webtrees.key
   ```

2. Install webtrees normally:

   ```bash
   ./install --proxy traefik --domain webtrees.lan
   ```

3. `docker compose up -d`. Traefik matches the requested SNI
   (`webtrees.lan`) against the cert store and serves your cert.

If the cert should also be Traefik's catch-all for unknown SNIs
(monitoring probes, IP-direct curls), add a
`tls.stores.default.defaultCertificate` block — but be aware that
this is a Traefik-instance-wide knob. On a shared Traefik that hosts
other services, the self-signed cert becomes the fallback for those
too. Use the global default only when webtrees is the sole consumer
or the self-signed cert is intentionally the catch-all.

### Pattern B: Caddy `tls internal`

If you don't run Traefik, Caddy can generate its own internal CA + a
matching leaf cert automatically. Put this on the host (webtrees
published on `28080` via the standalone overlay):

```caddyfile
webtrees.lan {
    tls internal
    reverse_proxy 127.0.0.1:28080 {
        header_up X-Forwarded-Proto https
    }
}
```

On first start Caddy generates a local root CA under its data
directory (`pki/authorities/local/` subpath; the data-dir base
varies — see Caddy's [conventions doc](https://caddyserver.com/docs/conventions)
for the per-platform / per-run-mode resolution of `XDG_DATA_HOME`)
and issues a leaf cert for the hostname. Keep the data directory on
persistent storage — wiping it forces a new root CA on next start
and every device's trust import has to be redone.

### Trust-store import: the operationally hard part

Both patterns shift the cost from "obtain a cert" to "make every
client trust it". Per-platform one-time cost:

- **Desktop browsers**: import the issuing CA's root cert into each
  OS / browser trust store once per machine.
- **iOS**: install a profile + manually toggle "Full Trust" under
  Settings → General → About → Certificate Trust Settings.
- **Android 7+**: user-installed CAs are not honoured for app
  network traffic by default; works for browsers, breaks for any
  mobile app that pins system trust.

Rough sizing rule for whether the per-device cost is worth paying:

| Client population | Realistic answer |
|---|---|
| Up to roughly five fixed devices, browser-only (typical family / homelab) | One-time import per device gives clean browser TLS forever. Pinned-system-trust clients (Android apps, native iOS apps that bypass the user CA store) still won't validate — see the Android note above. |
| Rotating BYOD, guest devices, or mixed app + browser access | Either accept the browser warning per visit, or move to an ACME-with-DNS-01 setup so the cert chains to a public CA. |

## Smoke verification

A plain HEAD request only proves the outer TLS listener answers — it
does not exercise the trust gate. Follow redirects so the typical
trust-gate failure surfaces as a visible loop instead of a deceptive
`HTTP/2 302`:

```bash
curl -fsSIL -o /dev/null -w '%{http_code}\n' https://webtrees.example.org/
```

Expected: a single `200` or `302` printed, curl exits 0.

Failure: curl exits with `curl: (47) Maximum (50) redirects
followed`. The in-container nginx never accepts the proxy's
`X-Forwarded-Proto: https` as trusted, so every request gets a 301
back to the same `https://` URL, the proxy forwards it on, and the
loop repeats until curl gives up. Fix `NGINX_TRUSTED_PROXIES` or the
proxy's header propagation before investigating the cert chain
itself.

For self-signed setups, add `--cacert /path/to/ca.pem` to validate
against your CA, or `--insecure` to confirm only that the listener
answers.

## Failure modes that are NOT cert problems

A surprising number of "HTTPS is broken" reports trace back to other
layers. Quick triage:

| Symptom | Likely cause | Fix |
|---|---|---|
| `ERR_TOO_MANY_REDIRECTS` | Trust gate refuses your proxy's `X-Forwarded-Proto: https` | Set `NGINX_TRUSTED_PROXIES=<proxy-cidr>` |
| Browser stays on `http://` | `ENFORCE_HTTPS=FALSE` in `.env` | `make switch-https` from the install dir |
| `Bad Gateway` | Webtrees container not healthy yet | `make logs`, wait for the entrypoint banner |
| Mixed-content warnings | Reverse proxy not setting `X-Forwarded-Proto` | Add `proxy_set_header X-Forwarded-Proto https;` (nginx) or `header_up X-Forwarded-Proto https` (Caddy) |
