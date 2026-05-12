# Phase 3 — Out-of-the-Box Self-Host Wizard: Doku-Trias + CI-Coverage

**Status:** scoped 2026-05-12, ready to execute.

**Voraussetzung:** Phase 2b shipped auf `main` (commits `ed3de56` … `68bd830`). Wizard fährt `--mode standalone` und `--mode dev`; Demo-Tree-Generator vorhanden; CI-Smoke-Matrix deckt `core | full | demo` ab.

## Ziel

Phase 3 schließt die drei dokumentierten Phase-2b-Lücken (Doku-Trias unvollständig, Demo-Import nicht CI-validiert) plus eine neu identifizierte CI-Lücke (`--mode dev` ungetestet in CI). Multi-PHP-Matrix (8.4 + 8.5) ist explizit *kein* Pillar — die wird parallel als laufende `versions.json`-Wartung erledigt.

## Scope

| | In Scope | Out of Scope (deferred) |
|---|---|---|
| **Doku** | `docs/developing.md`, `docs/customizing.md` (inkl. Backup-Section) | Migration-Doku für scripts/setup.sh-User (no-backward-compat-Linie aus Phase 2b bleibt) |
| **CI** | smoke-test-Zelle `dev` (rendert `.env`), neue E2E-Stage `demo-import` (importiert demo.ged in laufenden Stack) | Multi-PHP-Matrix (separate Wartung), Admin-Bootstrap-E2E (Phase 4) |
| **Wizard-Code** | Kein neuer Code; nur eventuelle Doku-Hooks (z.B. Banner-Text aktualisieren wenn customizing.md jetzt existiert) | Demo-Population-Knob, --local-user-id-Erweiterungen, neue Edition |

## Tasks (5 Stück, ~3-5h Gesamt)

---

### Task 1: `docs/developing.md`

**Files:**
- Create: `docs/developing.md` (~150 Zeilen)
- Modify: `README.md` "For module developers" Section (link in)

**Goal:** Modul-Entwickler-Doku, die sich an Maintainer richtet die das Repo clonen und am Wizard, Templates, oder den Docker-Images selbst arbeiten. Migriert die produktive Substanz aus der pre-Phase-2b-README (die ja entfernt wurde) auf ihre eigene Datei.

**Inhalt-Skeleton:**

```markdown
# webtrees-docker — Developer Guide

## Setup
- `git clone … && cd webtrees-docker`
- `./install --mode dev --non-interactive --proxy standalone --port 50010 ...`
- `make up` (oder `docker compose up -d`)

## Layout
- `installer/` — Python wizard (pytest, jest n/a)
- `rootfs/` — files baked into images at build time
- `app/` — bind-mounted source for `--mode dev`
- `Dockerfile` — multi-stage build (php-base, php-build, php-build-full, nginx-build, installer, buildbox)
- `compose.yaml` + `compose.*.yaml` — chain for standalone / pma / dev / publish / traefik / external-db

## Wizard development
- Tests: `cd installer && pytest`
- Build image: `docker build -f installer/Dockerfile -t webtrees-installer:dev .`
- Render-only check: `docker run --rm -v /tmp/work:/work webtrees-installer:dev --non-interactive --no-up …`

## Image builds
- Trigger: `gh workflow run build.yml --ref main` (manual) oder tag push `v*`
- Smoke-test cells: core / full / demo (siehe `.github/workflows/build.yml`)
- Multi-platform: linux/amd64 + linux/arm64 (qemu-emuliert für arm64)

## Common make targets
- `make up` / `make down` / `make build` / `make bash` / `make modules-shell`
- `make install` (composer install im buildbox)
- `make lang` (i18n-Sync)

## Module developer workflow (composer dev-link)
- `make link-base <pfad>` — Bind-mount eines lokalen Modul-Repos
- `make unlink-base` — wieder entfernen
- Live-Reload: phpfpm + min.js touch
```

**Steps:**
- [ ] Step 1.1: Existing developer-touchpoints inventarisieren via `git log -- README.md` rückwärts bis pre-Phase-2b und produktive Inhalte (make targets, layout, dev-flow) extrahieren.
- [ ] Step 1.2: `docs/developing.md` schreiben gemäß Skeleton. Sprache: Deutsch-mit-englischen-Code-Blocks (matched repo convention).
- [ ] Step 1.3: `README.md` — "For module developers"-Section schmaler machen, link auf `docs/developing.md`.
- [ ] Step 1.4: Markdown-Lint via `markdownlint-cli2`.
- [ ] Step 1.5: Commit:

```
Add the developer guide for module maintainers

The new docs/developing.md collects what the pre-Phase-2b
README documented for contributors: repo layout, wizard
build / test instructions, image-build trigger, common make
targets, and the module dev-link workflow. The README's
"For module developers" section now links into the guide.
```

---

### Task 2: `docs/customizing.md` mit Backup-Section

**Files:**
- Create: `docs/customizing.md` (~180 Zeilen)
- Modify: `README.md` "Customising" Section (link in, drop "next phase" Hinweis)

**Goal:** Self-Hoster-Customising-Guide. compose.override.yaml-Patterns + Backup-Section in einer Datei (per Scope-Decision).

**Inhalt-Skeleton:**

```markdown
# Customising your webtrees stack

## compose.override.yaml
Docker Compose merges `compose.override.yaml` (next to compose.yaml)
automatically. Place per-host customisations here so subsequent
wizard runs don't clobber them.

### Higher PHP limits
```yaml
services:
    phpfpm:
        environment:
            PHP_MEMORY_LIMIT: 512M
            PHP_POST_MAX_SIZE: 256M
            PHP_UPLOAD_MAX_FILESIZE: 256M
```

### Custom nginx snippet
```yaml
services:
    nginx:
        volumes:
            - ./my-nginx.conf:/etc/nginx/conf.d/custom/my.conf:ro
```

### External database
```yaml
services:
    db:
        deploy:
            replicas: 0
    phpfpm:
        environment:
            DB_HOST: db.example.org
            DB_PORT: "3306"
```
(Pair with `--use-external-db` in dev mode.)

### Your own webtrees modules
```yaml
services:
    phpfpm:
        volumes:
            - ./my-modules:/var/www/html/modules_v4:rw
```

## Backup

### Daily snapshot
```bash
# Database
docker compose exec -T db mariadb-dump \
    --all-databases --single-transaction --quick \
    | gzip > "backup-$(date +%F).sql.gz"

# Media
docker run --rm \
    -v webtrees_media:/m:ro \
    -v "$PWD:/host" \
    alpine:3.20 \
    tar -C /m -czf "/host/media-$(date +%F).tar.gz" .
```

### Restore
```bash
gunzip < backup-2026-05-12.sql.gz \
    | docker compose exec -T db mariadb

docker run --rm \
    -v webtrees_media:/m \
    -v "$PWD:/host" \
    alpine:3.20 \
    sh -c "cd /m && tar -xzf /host/media-2026-05-12.tar.gz"
```

### Schedule via cron / systemd-timer
(Beispiel-Schnipsel.)

## Per-environment configuration
- `.env` Variablen die der Wizard nicht schreibt aber `compose.yaml` liest
  (z.B. `WEBTREES_HTTPS_REDIRECT`, ...)
```

**Steps:**
- [ ] Step 2.1: `compose.yaml` + entrypoint-Scripts grep'en nach allen `ENV`-References und allen optionalen Pfaden (`/etc/nginx/conf.d/custom/`, ...) — die werden im Doc dokumentiert.
- [ ] Step 2.2: `docs/customizing.md` schreiben (Skeleton siehe oben).
- [ ] Step 2.3: `README.md` Customising-Section: link auf `docs/customizing.md`, drop "(Docs pending — Phase 3.)" und "wird im nächsten Phase nachgereicht".
- [ ] Step 2.4: Markdown-Lint.
- [ ] Step 2.5: Commit:

```
Add the customising guide with backup procedures

docs/customizing.md is the dedicated home for
compose.override.yaml patterns (PHP limits, custom nginx
snippets, external database, third-party modules) and a
Backup/Restore section covering mariadb-dump + media-tar
flows. The README's Customising paragraph drops its
"next phase" placeholder and links into the guide.
```

---

### Task 3: CI smoke cell `dev`

**Files:**
- Modify: `.github/workflows/build.yml` — `smoke-test` job

**Goal:** Vierte Matrix-Zelle `dev` smoket den `--mode dev`-Pfad: rendert `.env`, asserts compose-chain. Stack wird NICHT hochgefahren (dev braucht full clone + composer install, zu teuer für smoke).

**Steps:**
- [ ] Step 3.1: Matrix-Zeile erweitern: `edition: [core, full, demo, dev]`.
- [ ] Step 3.2: Im "Run installer (non-interactive)"-Step neuer `if [ "${EDITION}" = "dev" ]`-Branch:

```yaml
                  if [ "${EDITION}" = "dev" ]; then
                      git clone --depth 1 https://github.com/magicsunday/webtrees-docker.git "${SMOKE_DIR}/repo"
                      docker run --rm \
                          -v "${SMOKE_DIR}/repo:/work" \
                          -v /var/run/docker.sock:/var/run/docker.sock \
                          "ghcr.io/magicsunday/webtrees/installer:${INSTALLER_TAG}" \
                          --mode dev --non-interactive --force \
                          --proxy standalone --port "${SMOKE_PORT}" --pma-port 50011 \
                          --dev-domain webtrees.localhost:${SMOKE_PORT} \
                          --mariadb-root-password rootpw \
                          --mariadb-database webtrees \
                          --mariadb-user webtrees --mariadb-password devpw \
                          --local-user-id 1000 --local-user-name developer
                      test -f "${SMOKE_DIR}/repo/.env"
                      grep -q "^ENVIRONMENT=development$" "${SMOKE_DIR}/repo/.env"
                      grep -q "^COMPOSE_FILE=compose.yaml:compose.pma.yaml:compose.development.yaml:compose.publish.yaml$" "${SMOKE_DIR}/repo/.env"
                      grep -q "^LOCAL_USER_ID=1000$" "${SMOKE_DIR}/repo/.env"
                      echo "dev edition: .env rendered with expected dev-chain"
                      exit 0
                  fi
```
- [ ] Step 3.3: Vier Folge-Steps (`Up stack`, `Wait …`, `Probe HTTP`, `Tear down`) bekommen Guard-Update — Set `EDITION = demo` *oder* `dev` skipped.
- [ ] Step 3.4: actionlint.
- [ ] Step 3.5: Commit:

```
Add the dev edition to the smoke-test matrix

The fourth matrix cell exercises --mode dev against a
shallow clone of the repo, asserts the rendered .env
carries the expected dev compose-chain plus LOCAL_USER_ID,
and skips stack-up the same way the demo cell does. The
dev pipeline can't bring a stack up in smoke (full clone
+ composer install would dwarf the rest of the matrix),
so render-and-grep is the right gate for now.
```

---

### Task 4: CI Demo-Tree-Import E2E

**Files:**
- Modify: `.github/workflows/build.yml` — neuer Job `demo-import-e2e`

**Goal:** Die letzte Validation-Lücke schließen: `--demo --no-up`-Branch deckt nur GEDCOM-Generation; der `tree-import`-Pfad inkl. running stack + DB wartet ist heute *nur* durch lokales E2E gecovert. Phase 3 holt das in CI.

**Architektur:**
- Neuer separater Job (nicht in smoke-test-Matrix, weil zu teuer pro Zelle).
- Triggert nur wenn `smoke-test` grün ist (`needs: [smoke-test]`).
- Bringt einen vollen Stack hoch (single PHP-Version), wartet auf nginx + DB healthy, kopiert demo.ged in phpfpm, ruft `tree-import` via CLI, prüft via webtrees-CLI dass der Tree existiert.
- Edition: `full` (weil die charts mit Demo-Daten Sinn machen).

**Steps:**
- [ ] Step 4.1: Job-Definition schreiben (~80 YAML-Zeilen). Skeleton:

```yaml
    demo-import-e2e:
        name: demo-import E2E
        needs: [smoke-test]
        runs-on: ubuntu-latest
        env:
            SMOKE_DIR: /tmp/demo-import-e2e
            SMOKE_PORT: 18181
            INSTALLER_TAG: ${{ needs.matrix.outputs.installer_tag }}
        steps:
            - uses: actions/checkout@v6
            - name: Render stack via wizard
              run: ...   # --edition full --demo --no-up
            - name: Bring stack up
              working-directory: ${{ env.SMOKE_DIR }}
              run: docker compose up -d
            - name: Wait for nginx + db healthy
              run: ...   # 90s budget; mariadb takes ~30-60s
            - name: Copy GEDCOM + import
              run: |
                  docker compose cp "${SMOKE_DIR}/demo.ged" phpfpm:/tmp/demo.ged
                  docker compose exec -T phpfpm su www-data -s /bin/sh -c \
                      "php /var/www/html/index.php tree --create demo"
                  docker compose exec -T phpfpm su www-data -s /bin/sh -c \
                      "php /var/www/html/index.php tree-import demo /tmp/demo.ged"
            - name: Assert tree imported
              run: |
                  output=$(docker compose exec -T phpfpm su www-data -s /bin/sh -c \
                      "php /var/www/html/index.php tree-list")
                  echo "$output" | grep -q "^demo"
            - name: Tear down
              if: always()
              working-directory: ${{ env.SMOKE_DIR }}
              run: docker compose down -v
```
- [ ] Step 4.2: Lokales Pre-flight: den Job-Body als Shell-Script extrahieren und gegen die laufende NAS-Stack-Kopie probefahren um Healthcheck-Timing und tree-import-Exit-Codes zu kalibrieren.
- [ ] Step 4.3: actionlint.
- [ ] Step 4.4: Workflow_dispatch des Branches → Job läuft → grün-validieren.
- [ ] Step 4.5: Commit:

```
Add the demo-import E2E job

The smoke-test matrix's demo cell only proves the wizard
emits demo.ged; the actual `tree-import` CLI path
remained validated only by local E2E. The new
demo-import-e2e job brings the full stack up, waits for
nginx + db healthcheck, copies the GEDCOM into phpfpm,
runs tree --create + tree-import via the webtrees CLI,
and asserts via tree-list that the demo tree landed. Job
runs only after smoke-test is green so the registry-side
images are guaranteed valid.
```

---

### Task 5: E2E verification + spec sync

**Files:**
- Read-only verification der 4 vorherigen Tasks
- Modify: `docs/superpowers/specs/2026-05-11-out-of-the-box-self-host-design.md` (Phase-3-Status updaten)
- Modify: `~/.claude/projects/-volume2-docker-webtrees/memory/project_installer_phase2b_status.md` (Open items resolved → archive note)

**Goal:** Phase 3 abschließen: alle vier vorherigen Commits laufen lokal + CI grün, Spec markiert Phase 3 als shipped, Memory bereinigt.

**Steps:**
- [ ] Step 5.1: Build-Workflow erneut dispatchen + smoke-test (4 Zellen) + demo-import-e2e grün.
- [ ] Step 5.2: `docs/customizing.md` und `docs/developing.md` durch frische Augen lesen (Markdown-Render in einem Editor), Cross-Refs vom README aus klicken.
- [ ] Step 5.3: Spec-Sync: `2026-05-11-…design.md` Section "Doku" — die "Phase 2b liefert nur die erste"-Annotation entfernen, neue Phase-3-Liefergegenstände auflisten.
- [ ] Step 5.4: Memory-Note updaten: `project_installer_phase2b_status.md` → "Open items" sind alle resolved; archivieren oder zu `project_installer_phase3_status.md` rename.
- [ ] Step 5.5: Final-Commit nur falls Drift gefunden wurde:

```
Sync the spec with the shipped Phase 3 wizard documentation
…
```

## Acceptance Criteria

- `docs/developing.md` + `docs/customizing.md` existieren, sind verlinkt aus README, lesen sich als Standalone-Dokus.
- `.github/workflows/build.yml` smoke-test-Matrix hat 4 Zellen (core/full/demo/dev), alle grün auf Test-Dispatch.
- `demo-import-e2e`-Job grün, hängt korrekt an `smoke-test`.
- Spec dokumentiert die Phase-3-Liefergegenstände als shipped.
- Memory-Open-Items sind auf 0.

## Self-Review Checklist

- [ ] **Spec-Coverage:** Jede Spec-"Doku"-Zeile mappt auf einen Task hier.
- [ ] **No placeholder:** Kein `TBD`, `TODO`, `Phase 4 wird …` im finalen Plan.
- [ ] **Type consistency:** Keine neuen Frozen-Dataclasses; nur Doku + YAML.
- [ ] **Out-of-scope sauber gehalten:** Multi-PHP-Matrix, Migration-Doku, Admin-Bootstrap-E2E sind explizit gelistet als Out-of-Scope.

## Open Implementation Items (während Plan-Phase, hier vermerkt)

- Task 4 Step 4.2: lokales Pre-flight braucht Stack-Up auf nicht-50010-Ports (Live-Stack-Konflikt). NAS hat 18181 frei.
- Task 4: `tree-list`-Subkommando — checken ob in Webtrees-CLI exists; falls nicht: SQL-Query gegen `wt_gedcom` als Fallback.

## Migration aus Phase 2b

Keine. Phase 2b-Code bleibt unverändert; Phase 3 ist additive Doku + CI-Coverage.
