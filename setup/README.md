# `setup/` — composer manifests + vendor patches

Single source of truth for the composer manifests and `fisharebest/webtrees`
vendor patches applied during image build. One manifest per webtrees
major.minor line keeps the version-conditional surface (patch set, plugin
allow-list, chart constraints) directly in version-controlled JSON
instead of synthesised at build time.

## Files

| File | Purpose | Consumer |
| --- | --- | --- |
| `composer-core-<major.minor>.json` | Composer manifest for the core `php` image variant of that webtrees line — webtrees only, no bundled charts. | `Dockerfile` (`webtrees-build` stage), `install-application.sh` |
| `composer-full-<major.minor>.json` | Composer manifest for the `php-full` variant of that webtrees line — webtrees plus the version-matched Magic-Sunday fan / pedigree / descendants charts. | `Dockerfile` (`webtrees-build-full` stage) |
| `patches/disable-upgrade-prompt.patch` | Forces `UpgradeService::isUpgradeAvailable()` to return false. Referenced from every manifest (applies to every webtrees line). | `extra.patches` in all composer manifests |
| `patches/add-vendor-module-service.patch` | Adds `app/Services/Composer/VendorModuleService.php` and a `vendorModules()` hook in `ModuleService`. Bridges Composer's `InstalledVersions` API to webtrees' module registry. Referenced only from `composer-*-2.2.json` — webtrees 2.1.x lacks the `ModuleService` shape this patch's context anchors expect. | `extra.patches` in `composer-{core,full}-2.2.json` |
| `public/index.php` | Front-controller wrapper that bootstraps autoload and dispatches via `Webtrees::new()->run(PHP_SAPI)`. | Copied into the image at `/var/www/html/public/index.php` |
| `vendor/fisharebest/webtrees/data/config.ini.php` | Empty `config.ini.php` scaffold the entrypoint copies into `data/` for the browser-setup-wizard path. Real values are written at first boot. | `scripts/configuration` (dev bootstrap), entrypoint |

## Manifest selection

The `Dockerfile` and `install-application.sh` pick the manifest matching
`WEBTREES_VERSION`'s major.minor via a `case` (or POSIX parameter
expansion). Adding a new webtrees major.minor line (e.g. 3.0) requires
adding `setup/composer-core-3.0.json` + `setup/composer-full-3.0.json`
plus matching entries in the Dockerfile / install-application.sh `case`.
Manifests that diverge from each other outside the documented set are
caught by `ci-composer-patches-lockstep`.

## Documented divergence between manifests

The lockstep allows the manifests to differ on these keys, and only
these keys:

* `name`, `description` — core vs full
* `require["fisharebest/webtrees"]` — `~2.1.0` vs `~2.2.0`
* `require["magicsunday/webtrees-*"]` — full carries chart deps, core does not
* `config.allow-plugins["magicsunday/webtrees-module-installer-plugin"]` — 2.1 enables the installer-plugin (legacy module-wiring path); 2.2 disables it (charts wire via VendorModuleService instead)
* `extra.patches` — 2.2 carries the VendorModuleService entry; 2.1 does not

Every other key (authors, license, type, sort-packages, preferred-install, …)
MUST match byte-identically across all four manifests.

## Cross-file invariants

Each invariant is enforced by a `ci-*-lockstep` Make target.

| Invariant | Lockstep target |
| --- | --- |
| Manifests agree on every key outside the documented-divergence set; per-version `core`/`full` pairs carry identical `extra.patches` blocks | `ci-composer-patches-lockstep` |
| Every patch referenced from any manifest applies cleanly against the matching webtrees version in `dev/versions.json` | `ci-patches-apply-lockstep` |

## Patch lifecycle

* `disable-upgrade-prompt.patch` is **permanent**. The bundled image is
  immutable; bumping `WEBTREES_VERSION` is the only supported upgrade
  path. The patch forces `isUpgradeAvailable()` to return false so the
  admin UI's upgrade button never runs against an image-bound install.
* `add-vendor-module-service.patch` is **transitional**. When webtrees
  core lands an equivalent service, drop the reference from
  `composer-*-2.2.json` (and any future 2.x manifest that picks it up);
  the Dockerfile's post-apply sentinel grep
  (`merge($this->vendorModules())`) will then fail loud and flag the
  patch as redundant.

## Patch convention

Each patch file starts with a free-text intent paragraph(s), then a
blank line, then a standard `git format-patch` body. The intent
paragraph carries enough rationale that a reviewer can decide whether
the patch should still exist without reading the diff. Sentinel strings
the Dockerfile post-apply grep verifies (e.g. `Upgrade-lock: bundled
image is immutable`) MUST be unique to the patched hunk so a partially-
applied patch can be distinguished from an empty apply.

### Adding a new patch

1. Plant a sentinel string in the patch body that's unique to the hunk.
2. Add an `extra.patches.fisharebest/webtrees` entry referencing
   `patches/<filename>.patch` to every manifest the patch should apply
   to. The `ci-composer-patches-lockstep` invariant requires per-version
   `core`/`full` pairs to stay symmetric — add to both or to neither.
3. Add a post-apply grep guard in the `Dockerfile` `RUN` block.
4. Run `make ci-patches-apply-lockstep` to verify the patch applies
   against every webtrees version currently in `dev/versions.json`.

## Bumping webtrees

1. Bump the `webtrees` value(s) in `dev/versions.json`.
2. Run `make ci-patches-apply-lockstep` — fails loud if a patch no
   longer applies. Either regenerate the patch's context anchors against
   the new version, or drop the patch reference from the manifest of the
   version line that's outgrown it.
3. Run `make ci-test` for the full lockstep + lint pass.
