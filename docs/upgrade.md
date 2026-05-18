# Upgrading, switching modes, choosing a line

User-facing procedures for an existing webtrees-docker install:
moving to a newer webtrees release, switching between standalone /
dev mode, picking which webtrees line your install tracks. For
maintainer-side pin-bumping (Alpine / MariaDB / PHP base images),
see [`maintenance.md`](maintenance.md) instead.

## Updating to a new webtrees release

The fast path:

```bash
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/upgrade | bash
```

The `upgrade` launcher stops the stack, drops the `<project>_app`
volume so the new image can re-seed it, and re-runs the installer
with `--force`. The `<project>_database` and `<project>_media`
volumes survive the upgrade — your trees and uploaded media are
preserved. Pass custom flags via `bash -s -- --port 8443` if you
deviate from the quickstart defaults.

If you prefer to step through manually (audit each command before
it runs, or tweak individual steps):

```bash
docker compose down
docker volume rm "$(basename "$PWD")_app"
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install \
  | bash -s -- --non-interactive --no-admin --edition full --proxy standalone --port 28080 --force
docker compose pull
docker compose up -d
```

The drop-and-reseed of `<project>_app` is required: webtrees ships
its own code inside the image, the `<project>_app` volume mirrors
that code at first-boot, and a stale volume would override the new
image's files. The other two named volumes (`<project>_database`,
`<project>_media`) hold your data and **must not** be dropped.

## Switching modes

To toggle between standalone (production) and dev (module-maintainer):

```bash
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/switch | bash -s -- dev
curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/switch | bash -s -- standalone
```

If you cloned the repo you can also run `./switch dev` / `./switch
standalone` directly from the checkout. The launcher reads the
existing `.env`, stops the current stack, and re-runs the wizard with
the target mode — preserving the port, admin settings, and database
credentials you used before.

Switching INTO dev mode requires a git clone of this repo in the
current directory; the wizard refuses otherwise.

## Choosing a webtrees line

Two parallel image tracks are published:

| Tag | Webtrees line | PHP versions built | When to pick |
|---|---|---|---|
| `latest`, `2`, `2.2` | 2.2.x (current) | 8.3 / 8.4 / 8.5 | New installs, active feature work. |
| `2.1` | 2.1.x (LTS-style) | 8.3 / 8.4 / 8.5 | Stay on the older line until you are ready for the 2.1 → 2.2 upgrade. |

Pin a specific PHP minor with a fully-qualified tag — e.g.
`ghcr.io/magicsunday/webtrees-php:2.1.27-php8.4` or
`ghcr.io/magicsunday/webtrees-php:2.2.6-php8.5`. The line aliases
(`latest`, `2`, `2.1`, `2.2`) follow the rolling top-of-line PHP entry
(currently `php8.5`); pin a numeric tag if you need build determinism.

The 2.1 → 2.2 upgrade is a standard webtrees major bump: stop the
stack, swap the `WEBTREES_VERSION` value in `.env`, bring the stack
back up. Webtrees runs its own schema migrations on first start;
back up `<project>_database` first if the data matters to you.

## Related

- [`customizing.md`](customizing.md) — `compose.override.yaml`
  patterns (PHP limits, custom nginx snippets, third-party modules,
  backup / restore).
- [`installer-reference.md`](installer-reference.md) — every
  installer flag, grouped by scenario.
- [`maintenance.md`](maintenance.md) — maintainer-side pin bumping
  (Alpine / MariaDB / PHP).
- [`byod.md`](byod.md) — bring-your-own-data flags
  (`--use-external-db`, `--db-data-path`, `--reuse-volumes`).
