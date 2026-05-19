# `templates/` — pre-rendered operator-facing artefacts

Static files generated from the installer's Jinja sources at release
time so operators can import the stack into Portainer (or a similar
one-click deploy UI) without running the wizard. Hand-editing the
committed files breaks the lockstep with the renderer; edits must go
through the Jinja sources, then `make portainer-templates` re-renders.

## Files

| File | Purpose | Consumer |
| --- | --- | --- |
| `portainer/compose.yaml` | Full stack (init + db + phpfpm + nginx) for Portainer's Web-URL stack import. | Operators paste the raw URL into Portainer; CI lockstep checks. |
| `portainer/.env.example` | Documented env-var inventory matching the compose. Portainer's Web-URL flow does NOT auto-load the file — operators copy the values into Portainer's stack-UI env section. | Operators; CI lockstep checks. |

## Source of truth

| Rendered file | Jinja source |
| --- | --- |
| `portainer/compose.yaml` | `installer/webtrees_installer/templates/compose.standalone.j2` + `_compose_macros.j2` |
| `portainer/.env.example` | `installer/webtrees_installer/templates/env.j2` |

The renderer is `scripts/render-portainer-templates.sh`. Invoke via
`make portainer-templates`. It pins `generated_at` to a fixed sentinel
so re-runs produce byte-stable output; the `.env` timestamp comment is
sed-stripped to a generic header.

## Re-render workflow

1. Edit the Jinja source(s) under `installer/webtrees_installer/templates/`.
2. Run `make portainer-templates`.
3. `git diff templates/portainer/` — confirm only the intended changes
   landed.
4. Commit the Jinja source change AND the regenerated files in the same
   commit. `ci-portainer-templates-lockstep` enforces the pairing.

## Cross-file invariants

| Invariant | Lockstep target |
| --- | --- |
| `templates/portainer/{compose.yaml,.env.example}` byte-identical to a fresh render | `ci-portainer-templates-lockstep` |
| Pinned image tags + healthcheck values + port defaults mirror their narrower canonical sources | `ci-alpine-lockstep`, `ci-healthcheck-lockstep`, `ci-port-default-lockstep`, `test_mariadb_pin_lockstep`, `test_nginx_tag_lockstep` |

The byte-equality check subsumes the narrower pin checks (anything that
changes the rendered output triggers it), but the narrower checks
remain as defence-in-depth — they fail with focused error messages
(`mariadb pin drift`, `nginx tag drift`) rather than a raw diff.

## Editing rules

* `compose.yaml` is byte-locked to the renderer. Any hand-edit will be
  reverted by the next `make portainer-templates` run AND fail
  `ci-portainer-templates-lockstep` until reverted.
* `.env.example`'s **values** are byte-locked too (they document the
  rendered defaults). Operators DO edit the values in Portainer's
  stack-UI env section at deploy time — that is fine and expected; the
  committed file is the canonical pre-render they start from.
