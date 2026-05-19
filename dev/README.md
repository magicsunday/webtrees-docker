# `dev/` — canonical pin metadata

Single source of truth for every image pin the build pipeline consumes.
The four polling workflows (`.github/workflows/check-*.yml`) write to
these files; the build workflow (`build.yml`) and the lockstep checks in
`scripts/lockstep/` read from them.

## Files

| File | Purpose | Schema |
| --- | --- | --- |
| `versions.json` | webtrees × PHP catalog (the build matrix). | `[{webtrees: "X.Y.Z", php: "A.B", tags: [...]}, …]` |
| `nginx-version.json` | nginx image pin (own tag track). | `{nginx_base: "X.Y", config_revision: N, tag: "X.Y-rN"}` |
| `installer-version.json` | installer release pin. | `{version: "X.Y.Z"}` |
| `php-versions.json` | supported PHP minors (SoT). | `{supported: ["A.B", ...]}` |
| `php_digests.lock` | multi-arch manifest digest snapshot per PHP minor (for rebuild triggers + Dockerfile FROM digest-pin). | `<minor>=sha256:<64-hex>` per line, sorted, one per `.supported` entry. |

## Cross-file invariants

The following must hold across the five files. Each invariant is enforced
by a `ci-*-lockstep` Make target.

| Invariant | Lockstep target |
| --- | --- |
| `php-versions.json .supported` == unique `versions.json[].php` set, per webtrees minor | `ci-php-versions-lockstep` |
| `nginx-version.json .tag` == `<nginx_base>-r<config_revision>` | `ci-nginx-tag-derivation-lockstep` |
| `php_digests.lock` keys == `php-versions.json .supported`, line shape `<minor>=sha256:<hex>` | `ci-php-digests-lockstep` |
| Exactly one `versions.json` row carries `"latest"`, on the semver-max webtrees | `ci-versions-latest-semver-max-lockstep` |
| `.env.dist` `WEBTREES_VERSION` / `WEBTREES_NGINX_VERSION` / `NGINX_CONFIG_REVISION` / `PHP_VERSION` mirror their `dev/` sources | `ci-env-dist-pins-lockstep` |
| `Dockerfile` `ARG PHP_VERSION` / `WEBTREES_VERSION` / `NGINX_BASE` / `NGINX_CONFIG_REVISION` defaults match `.env.dist` | `ci-dockerfile-arg-defaults-lockstep` |

(`ci-images-lockstep` is orthogonal — it mirrors `Make/images.mk` ↔
`scripts/lib/images.env` for CI-tooling pins like jq/hadolint/shellcheck,
which live outside `dev/`.)

## Conventions

- JSON files use 4-space indent. `versions.json` rows are kept on a
  single line each so a tag-set bump produces a one-line diff;
  `scripts/workflow/batch-bump-webtrees-versions.sh` writes back this
  shape via `jq -c`.
- `versions.json` rows always emit `tags: []` even when no extra tags
  apply — the loader (`installer/webtrees_installer/versions.py`) reads
  the field unconditionally.
- `php_digests.lock` is plain `<minor>=sha256:<hex>` for grep-friendly
  diffs and for the Dockerfile build-arg path (`PHP_DIGEST_REF`); the
  format is enforced line-by-line in `ci-php-digests-lockstep`.

## Adding a new PHP minor

1. Add the minor to `php-versions.json .supported`.
2. Add a row per tracked webtrees version to `versions.json`.
3. Run `make ci-test` — `ci-php-versions-lockstep` confirms (1) and (2)
   agree; the next `check-php.yml` cron tick seeds the matching entry
   in `php_digests.lock`. Until then, `ci-php-digests-lockstep` will
   fail; run the workflow manually (or wait one cron tick) to populate
   the digest snapshot.

## Bumping nginx

- Base bump only (1.30 → 1.31): bump `nginx_base`, reset
  `config_revision` to 1, set `tag` to the derived form. Run
  `make ci-test`.
- Config-only bump (rootfs/etc/nginx/ edits): bump `config_revision`,
  set `tag` to the new derived form. Run `make ci-test`.
- In both cases, mirror `WEBTREES_NGINX_VERSION` and
  `NGINX_CONFIG_REVISION` in `.env.dist` (caught by
  `ci-env-dist-pins-lockstep`) AND `NGINX_BASE` / `NGINX_CONFIG_REVISION`
  defaults in `Dockerfile` (caught by `ci-dockerfile-arg-defaults-lockstep`).
