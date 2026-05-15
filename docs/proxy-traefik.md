# Traefik reverse-proxy walkthrough

This is the long-form walkthrough for landing webtrees behind a
host-level Traefik instance with TLS termination at the edge. For the
flag-level reference of every installer option see
[`installer-reference.md`](installer-reference.md).

## What you need first

The installer assumes Traefik is already running and listening on the
docker socket. The walkthrough below covers the webtrees side; the
Traefik side is a one-time setup the operator owns.

| Pre-requisite | Why |
|---|---|
| **A Traefik instance reachable on a Docker network named `traefik`** | The wizard joins the rendered stack to an external network whose name is currently hard-coded to `traefik` in the rendered compose. Operators whose Traefik runs on a network with a different name need the override workflow at the bottom of this page. A `--traefik-network <name>` installer flag is tracked separately. |
| **An ACME / Let's Encrypt resolver on that Traefik** | Webtrees ships `ENFORCE_HTTPS=TRUE`; the rendered router pins `tls=true` + the `websecure` entrypoint. Without a working cert resolver, browsers will hit a TLS error before reaching webtrees. The cert workflow itself is tracked in issue #44 — this walkthrough assumes the Traefik admin has already wired ACME (e.g. via `traefik.yml` `certificatesResolvers`). |
| **A DNS record pointing the chosen hostname at the Traefik host** | A `webtrees.example.com` A or CNAME record must resolve to the IP Traefik publishes its `websecure` entrypoint on, otherwise ACME's HTTP-01 / DNS-01 challenge cannot complete. |
| **Traefik configured to accept Docker labels** | `--providers.docker=true` on the Traefik command line (or the equivalent file-provider config). The wizard emits standard `traefik.http.routers.*` labels; nothing custom. |

## Bringing webtrees up

The simplest invocation, given the four pre-requisites above:

```bash
./install \
    --proxy traefik \
    --domain webtrees.example.com \
    --edition full \
    --admin-user admin \
    --admin-email admin@example.com
```

The wizard renders `compose.yaml` + `.env`, joins the stack to the
`traefik` external network, and runs `docker compose up -d`. Traefik
picks up the new container labels within a few seconds; the first
request to `https://webtrees.example.com` triggers ACME issuance if
the cert isn't already cached.

The admin password is printed once in the install banner. Save it
before closing the terminal — the wizard does not write it to disk.

## What the wizard generates

The rendered `compose.yaml` emits the following labels on the nginx
service (substituting the actual `--domain` value):

```yaml
labels:
    traefik.enable: "true"
    traefik.docker.network: "traefik"
    traefik.http.routers.webtrees.rule: "Host(`webtrees.example.com`)"
    traefik.http.routers.webtrees.entrypoints: "websecure"
    traefik.http.routers.webtrees.tls: "true"
    traefik.http.services.webtrees.loadbalancer.server.port: "80"
```

Notable: the router name is `webtrees` regardless of the
compose-project name. If you run multiple webtrees instances on the
same Traefik host (e.g. one per family branch), pass
`COMPOSE_PROJECT_NAME=webtrees-greys ./install …` and Traefik will
distinguish them by the project name in the router label namespace.

## Custom Traefik network names

The wizard currently renders `traefik` as the network name in both the
`traefik.docker.network` label and the `networks:` section. To use a
different name (e.g. `proxy`, `edge-net`), render the stack with
`--no-up`, then patch both occurrences in `compose.yaml` before
bringing the stack up:

```bash
./install --proxy traefik --domain webtrees.example.com --no-up
sed -i 's|name: traefik|name: proxy|' compose.yaml
sed -i 's|traefik.docker.network: "traefik"|traefik.docker.network: "proxy"|' compose.yaml
docker compose up -d
```

A `--traefik-network <name>` installer flag (issue #93) will land in a
later release so the manual patch is no longer needed.

## Adding to an existing compose stack

If you already have a hand-rolled webtrees stack and want to slide it
behind your Traefik, the minimum overlay is:

```yaml
# compose.override.yaml
services:
    nginx:
        labels:
            traefik.enable: "true"
            traefik.docker.network: "traefik"
            traefik.http.routers.my-webtrees.rule: "Host(`webtrees.example.com`)"
            traefik.http.routers.my-webtrees.entrypoints: "websecure"
            traefik.http.routers.my-webtrees.tls: "true"
            traefik.http.services.my-webtrees.loadbalancer.server.port: "80"
        networks:
            - default
            - traefik
        # Remove the host-published port; Traefik takes over routing.
        ports: !reset []
        environment:
            ENFORCE_HTTPS: "TRUE"

networks:
    traefik:
        external: true
        name: traefik
```

`!reset []` is compose v2.27+ syntax for explicitly clearing the
`ports:` mapping from the base file — important because publishing the
host port AND routing through Traefik causes label collisions and
double-binding.

The router name (`my-webtrees` above) must be unique across every
service Traefik routes. The wizard's default is `webtrees`; a
hand-rolled overlay should namespace by the operator's own convention.

## Troubleshooting

### TLS error on first hit

Traefik's ACME resolver issues certs lazily, on the first request to
the configured `websecure` entrypoint. Wait 30-60 seconds after the
stack comes up, then refresh. If the error persists:

```bash
docker logs traefik 2>&1 | grep -i 'acme\|certificate'
```

Look for `unable to obtain ACME certificate` and follow the resolver
diagnostics in the Traefik logs. Most failures are: missing DNS
record, wrong DNS provider credentials, or ACME rate-limit hits from
prior failed attempts (in which case the resolver pauses for hours).

### Router conflict — "Router already exists"

Two services emit the same router name. Either rename the new
service's router label or override the wizard's default by setting
`COMPOSE_PROJECT_NAME` so the rendered name picks up the suffix.

### Wrong Docker network

Symptoms: `502 Bad Gateway` on every request even though webtrees is
healthy. Cause: Traefik is on network `proxy` but the wizard joined
the stack to `traefik`. Run `docker network ls` to confirm, then
re-render with `--traefik-network <correct-name> --force`.

### Mixed-content warnings under `ENFORCE_HTTPS=TRUE` + `--no-https`

Don't combine those two — the wizard rejects the combination
explicitly. The rendered Traefik router still terminates TLS at the
edge, so `ENFORCE_HTTPS=FALSE` would suppress HSTS / CSP at the app
layer while the browser stays on HTTPS. See
[customizing.md → HTTPS trust gate](customizing.md) for the full
rationale.

### Sibling container spoofing X-Forwarded-Proto

If you run additional containers in the same docker network as the
webtrees stack, those containers can spoof the `X-Forwarded-Proto`
header against nginx. The trust gate (`172.16.0.0/12` etc.) closes
the LAN-attacker path but treats sibling containers as in-network
trust. See the *Sibling-container caveat* in customizing.md.
