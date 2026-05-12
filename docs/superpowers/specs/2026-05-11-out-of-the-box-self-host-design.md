# Out-of-the-Box Self-Host für webtrees-docker

**Datum:** 2026-05-11
**Cluster:** A — Out-of-the-Box Self-Host
**Status:** Spec, bereit für Plan-Phase

## Ziel

Ein neuer Endnutzer soll mit einer einzigen `docker run`-Zeile ein lauffähiges Webtrees mit Magic-Sunday-Modulen erhalten — ohne `git clone`, ohne `.env` editieren, ohne den Webtrees-Browser-Setup-Wizard durchklicken zu müssen. Modul-Entwickler behalten ihren bestehenden Repo-Workflow mit Bind-Mount, Buildbox und xdebug.

## Getroffene Architekturentscheidungen

| # | Entscheidung |
|---|---|
| 1 | **3-Container-Modell** (db + phpfpm + nginx) bleibt für Self-Host und Dev. Kein AIO-Image. |
| 2 | **Zero-Config-Start**: User braucht keine `.env`-Datei. Ein One-Shot `init`-Service generiert beim ersten `up` zufällige DB-Passwörter. |
| 3 | **Shared-Volume + `_FILE`-Pattern**: Secrets liegen in einem `secrets:`-Named-Volume und werden von db und phpfpm als `*_FILE`-Pfade gelesen. Berechtigungen `chmod 444` nach Generierung. |
| 4 | **`webtrees-nginx`-Image mit eigenem Tag-Track**, entkoppelt von Webtrees-/PHP-Versionen. Tag-Schema `webtrees-nginx:<nginx-base>-r<rev>` (z. B. `1.28-r1`). |
| 5 | **Wizard in Python, ausgeführt im Container** (`webtrees-installer`-Image). User-Aufruf: `docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD:/work" ghcr.io/magicsunday/webtrees-installer:latest`. Zero Host-Dependencies außer Docker. |
| 6 | **Proxy-Modi: Standalone + Traefik**. Kein Caddy, kein Nginx-Proxy-Manager. |
| 7 | **Editionen: Core + Magic-Sunday-Full + Full-mit-Demo-Tree**. Demo-Tree wird vom Installer generiert (kein gepacktes GEDCOM). |
| 8 | **Ein Wizard-Skript mit Mode-Flag** (`--mode standalone` / `--mode dev`). `scripts/setup.sh` wird ersetzt und entfernt — keine Backward-Compat. |
| 9 | **Magic-Sunday-Module landen in `vendor/magicsunday/...`** und werden vom existierenden VendorModuleService-Patch geladen. **Kein** `magicsunday/webtrees-module-installer-plugin` in der Full-Edition. |
| 10 | **Headless-Webtrees-Setup für Admin-Bootstrap nur via Pfad A** (direkt `config.ini.php` schreiben + Webtrees-CLI). Kein HTTP-POST-Fallback. |
| 11 | **`compose.override.yaml`-Pattern als User-Schnittstelle** für Anpassungen. Wizard schreibt nur das Basis-`compose.yaml`. |
| 12 | **Port-Konflikt-Live-Check** via temporären Alpine-Container mit `--network host` + `nc`. Loopt bis ein freier Port gefunden ist. |
| 13 | **Spec-Sprache Deutsch**, Doku (README + docs/) in **Englisch** (konsistent mit Repo-Sprache und OCI-Labels). |

## Architektur

### Image-Spuren

| Image | Tag-Schema | Zweck | Status |
|---|---|---|---|
| `webtrees-php` | `<wt>-php<x>` | PHP-FPM + webtrees core | refactored |
| `webtrees-php-full` | `<wt>-php<x>` | + Magic-Sunday-Module pre-baked | neu |
| `webtrees-nginx` | `<nginx>-r<rev>` | nginx mit Configs, eigener Track | neu |
| `webtrees-installer` | `<installer-rev>` | Python-Wizard | neu |
| `webtrees-buildbox` | `<wt>-php<x>` | Dev-Tooling (xdebug, node, gh) | unverändert |

### Dockerfile-Struktur

```
webtrees-build       (FROM composer:2)
  ├─ installiert webtrees core aus setup/composer-core.json
  └─ wendet Patches an (upgrade-lock, VendorModuleService)

webtrees-build-full  (FROM composer:2)
  └─ wie webtrees-build, aber lädt setup/composer-full.json
     → enthält von Anfang an magicsunday/webtrees-{fan,pedigree,
       descendants}-chart in require (statistics deferred —
       Modul ist nicht auf Packagist publiziert)

php-base             (FROM php:<x>-fpm-alpine)
  ├─ installiert PHP-Extensions (incl. pdo_sqlite — Vorbereitung Cluster B)
  ├─ kopiert rootfs/{php-conf,docker-entrypoint.sh}
  └─ erweiterter Entrypoint mit Admin-Bootstrap-Hook

php-build            (FROM php-base)
  └─ COPY --from=webtrees-build /opt/webtrees-dist

php-build-full       (FROM php-base)
  └─ COPY --from=webtrees-build-full /opt/webtrees-dist

nginx-build          (FROM nginx:1.28-alpine)
  ├─ COPY rootfs/etc/nginx/
  ├─ mkdir /etc/nginx/conf.d/custom/  (leeres Override-Verzeichnis)
  └─ default.conf erweitert um: include /etc/nginx/conf.d/custom/*.conf;

buildbox             (FROM php-build)
  └─ unverändert: xdebug, node, git, gh, nano, etc.
```

`Dockerfile.installer` separat (Python-Basisimage divergiert von php-fpm-alpine):

```
python:3.12-alpine
  ├─ pip install questionary rich jinja2 pyyaml
  ├─ COPY installer/ /app/
  ├─ COPY dev/versions.json dev/nginx-version.json dev/installer-version.json /app/
  └─ ENTRYPOINT ["python", "-m", "webtrees_installer"]
```

### Compose-Templates (im Installer-Image)

`installer/webtrees_installer/templates/compose.standalone.j2`, `compose.traefik.j2`, `env.j2`. Wizard rendert das passende Template mit den User-Werten und Image-Tags aus `versions.json`. (`compose.dev.j2` kommt in Phase 2b zusammen mit der Dev-Flow-Migration.)

Kern-Struktur der generierten `compose.yaml` (Standalone-Modus, Edition-agnostisch):

```yaml
name: webtrees

volumes:
  secrets:
  database:
  app:
  media:

services:
  init:
    image: alpine:3.20
    restart: "no"
    volumes: [ "secrets:/secrets" ]
    command:
      - sh
      - -ec
      - |
          umask 077
          for name in mariadb_root_password mariadb_password{% if admin_bootstrap %} wt_admin_password{% endif %}; do
            if [ ! -s "/secrets/$name" ]; then
              head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "/secrets/$name"
            fi
          done
          chmod 444 /secrets/*

  db:
    image: mariadb:11.7
    depends_on: { init: { condition: service_completed_successfully } }
    environment:
      MARIADB_ROOT_PASSWORD_FILE: /secrets/mariadb_root_password
      MARIADB_USER: webtrees
      MARIADB_PASSWORD_FILE: /secrets/mariadb_password
      MARIADB_DATABASE: webtrees
    volumes:
      - secrets:/secrets:ro
      - database:/var/lib/mysql
    healthcheck: { ... }

  phpfpm:
    image: ghcr.io/magicsunday/webtrees/php{{ '-full' if edition == 'full' else '' }}:{{ wt_version }}-php{{ php_version }}
    depends_on: { db: { condition: service_healthy } }
    environment:
      ENVIRONMENT: production
      WEBTREES_VERSION: {{ wt_version }}
      WEBTREES_AUTO_SEED: "true"
      MARIADB_HOST: db
      MARIADB_USER: webtrees
      MARIADB_DATABASE: webtrees
      MARIADB_PASSWORD_FILE: /secrets/mariadb_password
      {% if admin_bootstrap %}
      WT_ADMIN_USER: {{ admin_user }}
      WT_ADMIN_EMAIL: {{ admin_email }}
      WT_ADMIN_PASSWORD_FILE: /secrets/wt_admin_password
      {% endif %}
    volumes:
      - secrets:/secrets:ro
      - app:/var/www/html
      - media:/var/www/html/data/media

  nginx:
    image: ghcr.io/magicsunday/webtrees/nginx:{{ nginx_tag }}
    depends_on: { phpfpm: { condition: service_healthy } }
    {% if proxy_mode == 'standalone' %}
    ports: [ "${APP_PORT:-{{ chosen_port }}}:80" ]
    {% else %}
    networks: [ default, traefik ]
    labels: [ ... Traefik-Labels ... ]
    {% endif %}
    volumes:
      - app:/var/www/html:ro
      - media:/var/www/html/data/media:ro

{% if proxy_mode == 'traefik' %}
networks:
  default:
  traefik:
    external: true
    name: {{ traefik_network }}
{% endif %}
```

### Was *nicht* generiert wird

- **Kein phpMyAdmin** — Dev-Tool, gehört nicht ins Self-Host-Standard.
- **Kein External-DB-Pfad** — Power-Use-Case, in `compose.override.yaml`.
- **Kein Modules-Bind-Mount für Core-Edition** — wer Module dazustellen will, nutzt Override-Datei (Doku zeigt Snippet).
- **Kein SQLite-Pfad** — bewusst draußen, gehört in Cluster B.
- **Kein TLS auf Standalone (443-Port)** — Cluster B.

## Wizard-Flow

### Aufruf

```shell
docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:/work" \
  ghcr.io/magicsunday/webtrees-installer:latest
```

Optionaler Bash-Wrapper im Repo unter `install` (~10 Zeilen, ruft den `docker run` auf): `curl -fsSL https://raw.githubusercontent.com/magicsunday/webtrees-docker/main/install | bash`.

### Standalone-Flow

1. **Prerequisite-Check**: Docker erreichbar, Compose v2, `/work` gemountet, `/var/run/docker.sock` gemountet.
2. **Existing-File-Guard**: `compose.yaml` in `/work`? → Override-Prompt (default N).
3. **Edition-Wahl**: Core / Full / Full + Demo-Tree (default Full).
4. **Reverse-Proxy-Wahl**: Standalone / Traefik (default Standalone).
5. **Port- oder Domain-Eingabe**: bei Standalone Port (default 80, Live-Check via Alpine-Container, Fallback 8080); bei Traefik Domain (pflicht).
6. **Admin-Bootstrap**: y/N (default y). Bei y: Username, Email. Passwort wird vom Wizard via `secrets.token_hex(12)` (24 hex chars, 96 bit) generiert und nach Stack-Start ausgegeben.
7. **Demo-Tree-Seed** (nur bei Demo-Edition, optional): `--demo-seed <int>` (default 42). Die Baumgröße ist implizit (7 Generationen × Kinderzahl-Range ≈ 100–400 Personen pro Seed); ein expliziter Population-Knopf wird aktuell nicht angeboten — Seed-Variation reicht für Demo-Zwecke.
8. **Zusammenfassung + Bestätigung**.
9. **Files schreiben**: `compose.yaml` (Jinja) und `.env` (Architektur-Werte: COMPOSE_PROJECT_NAME, WEBTREES_VERSION, PHP_VERSION, WEBTREES_NGINX_VERSION, im Standalone-Modus zusätzlich APP_PORT). Phase 2b: `demo.ged` bei Demo-Edition.
10. **Admin-Passwort persistieren** (nur bei Admin-Bootstrap): Wizard legt das `webtrees_secrets`-Volume mit `docker volume create` an und schreibt das generierte Passwort über einen kurzlebigen Alpine-Container nach `/secrets/wt_admin_password` (chmod 444). Parallel dazu wird `.webtrees-admin-password` im Work-Dir mit Mode 0600 abgelegt, damit der User es nach dem ersten Login löschen kann. Der `init`-Service findet die Datei beim Stack-Start gefüllt und überschreibt sie nicht.
11. **Optional**: `docker compose up -d` direkt ausführen; Warten auf nginx-Healthcheck (Timeout 60s); bei Demo + Admin (Phase 2b): Stack hochfahren → Marker-File abwarten → `compose cp` GEDCOM → `tree-import` via CLI.
12. **Banner**: URL, Admin-Login + generiertes Passwort, Hinweis auf `compose.override.yaml` und gängige Compose-Befehle.

### Dev-Flow (`--mode dev`)

Setzt voraus, dass `/work` ein geklontes `webtrees-docker`-Repo ist (Sanity-Check: `Dockerfile` + `compose.yaml` existieren).

1. **Repo-Sanity-Check**.
2. **Prompts** (analog heutigem `setup.sh`, in Python neu geschrieben):
   - Reverse-Proxy: Standalone / Traefik
   - `DEV_DOMAIN`
   - Existing-DB initialisiert? (`USE_EXISTING_DB`)
   - External-DB? Falls ja: `MARIADB_HOST`
   - DB-Creds (Root-PW, DB-Name, User, User-PW)
   - PMA einschließen? (default y)
3. **`.env` schreiben**: COMPOSE_FILE-Chain, DB-Vars, `LOCAL_USER_ID`/`LOCAL_USER_NAME`, `APP_PORT`/`PMA_PORT`, `DEV_DOMAIN`.
4. **Persistent-Verzeichnisse anlegen** (`persistent/database`, `persistent/media`, `app/`).
5. **Image-Pull** (`docker compose pull`).
6. **App-Bootstrap** (Composer-Install im Buildbox, entspricht heutigem `make install`).
7. **Banner** mit `make up`/`docker compose up -d` als nächste Schritte.

`LOCAL_USER_ID`/`LOCAL_USER_NAME` werden über die CLI-Flags `--local-user-id`/`--local-user-name` gesetzt. Der `install`-Launcher prependet automatisch `--local-user-id $(id -u)` und `--local-user-name $(id -un)` vor den User-Argumenten, sodass der typische `curl | bash`-Aufruf die echte Host-UID einsetzt. Wer das Installer-Image direkt per `docker run` startet, muss die beiden Flags selbst übergeben — sonst landet `LOCAL_USER_ID=0` in der `.env` und das Buildbox-User-Mapping ist gebrochen.

Edition-Wahl entfällt im Dev-Modus — die Edition ist durch `setup/composer.json` bestimmt.

### Non-Interactive-Modus

Für CI und Skripted-Deployments unterstützt der Wizard `--non-interactive` + Flags für jeden Prompt: `--edition core|full`, `--proxy standalone|traefik`, `--port <int>` (Standalone), `--domain <host>` (Traefik), `--admin-user`, `--admin-email`, `--no-admin`, `--no-up`, `--force` (überschreibt vorhandene `compose.yaml` / `.env` ohne Prompt). Phase 2b ergänzt `--demo` (opt-in, generiert ein 7-Generationen-GEDCOM und importiert es bei aktivem Stack), `--demo-seed <int>` und `--mode dev`.

### Edge-Cases

| Fall | Verhalten |
|---|---|
| `/var/run/docker.sock` nicht gemountet | Exit 1 + Korrekturzeile |
| `/work` nicht gemountet | Exit 1 + korrektes `docker run`-Beispiel |
| Docker daemon nicht erreichbar | Exit 1 + Permission-/Gruppen-Hinweis |
| Compose v1 statt v2 | Exit 1, "Compose v2 required" |
| `compose.yaml` existiert in `/work` | Override-Prompt (default N) |
| `.env` existiert (Standalone) | Override-Prompt, Warnung über Werte-Verlust |
| Port belegt (Standalone) | Live-Check + Fallback-Vorschlag, Loop bis frei |
| Demo-Edition + Admin-Bootstrap aus | Inkonsistenz, Wizard besteht auf Admin |
| User wählt "kein Stack-Start" | Files bleiben, Anleitung "Now run: docker compose up -d" |
| Wizard-Re-Run mit gleicher Config | Override-Prompts, idempotent in Output-Files |

## Admin-Bootstrap

### Lebensort

Im **`webtrees-php`-Image-Entrypoint** (`rootfs/docker-entrypoint.sh`), neue Funktion `setup_webtrees_bootstrap`. Marker `/var/www/html/.webtrees-bootstrapped` (innerhalb des persistenten Volumes, damit Container-Recreate den Hook nicht erneut auslöst), idempotent.

### Passwort-Übergabe (Wizard → Bootstrap-Hook)

Der Wizard erzeugt das Admin-Passwort lokal (`secrets.token_hex(12)`) und gibt es nach dem File-Write im Banner aus. Damit der Bootstrap-Hook beim ersten `up -d` exakt dieses Passwort verwendet, schreibt der Wizard es vor dem Stack-Start in das `webtrees_secrets`-Volume:

1. `docker volume create webtrees_secrets` (idempotent).
2. Ephemerer Alpine-Container schreibt `umask 077 && cat > /secrets/wt_admin_password && chmod 444` (stdin-fed, kein Argv-Leak).
3. Schlägt Schritt 2 fehl, entfernt der Wizard das Volume wieder (sauberer Re-Run).
4. Zusätzlich landet das Passwort als `.webtrees-admin-password` (Mode 0600) im Work-Dir als Reveal-File für den User; der Banner verweist explizit darauf.

Der `init`-Service im generierten `compose.yaml` prüft `[ -s "/secrets/wt_admin_password" ]` und überschreibt vorhandene Inhalte nicht — d. h. das wizard-seitig vorbeireitete Passwort gewinnt.

### Pfad A: `config.ini.php` + Webtrees-CLI

```bash
if [[ -n "${WT_ADMIN_USER:-}" && ! -f /var/www/html/data/config.ini.php ]]; then
    cat > /var/www/html/data/config.ini.php <<EOF
dbtype="mysql"
dbhost="$MARIADB_HOST"
dbname="$MARIADB_DATABASE"
dbuser="$MARIADB_USER"
dbpass="$(cat "$MARIADB_PASSWORD_FILE")"
tblpfx="wt_"
EOF
    chown www-data:www-data /var/www/html/data/config.ini.php
    chmod 600 /var/www/html/data/config.ini.php

    su www-data -s /bin/sh -c '
        php /var/www/html/index.php migrate &&
        php /var/www/html/index.php user --create \
            --username "$WT_ADMIN_USER" \
            --realname "$WT_ADMIN_USER" \
            --email "$WT_ADMIN_EMAIL" \
            --password "$(cat "$WT_ADMIN_PASSWORD_FILE")" \
            --admin
    '

    touch /var/www/html/.webtrees-bootstrapped
fi
```

### Failure-Modes

| Failure | Verhalten |
|---|---|
| `config.ini.php` schreiben failt | Marker nicht setzen, Exit 1, Container restart-Loop |
| Migrate failt (DB nicht ready, falscher User) | Marker nicht setzen, Retry beim nächsten Start |
| `user --create` failt (User existiert schon) | Tolerieren, Marker setzen |
| `WT_ADMIN_USER` gesetzt, `WT_ADMIN_PASSWORD_FILE` fehlt | Exit 1 vor jeder Aktion |
| `WT_ADMIN_USER` nicht gesetzt | Bootstrap-Hook macht nichts; Webtrees-Browser-Wizard läuft wie heute |

## Demo-Tree

### Generator

Python-Modul im Installer-Image: `installer/demo_tree/generator.py`.

Datenmodell:

```python
@dataclass
class Person:
    xref: str
    given_name: str
    surname: str
    sex: Literal["M", "F"]
    birth_year: int
    death_year: int | None
    parents_family: str | None
    own_family: str | None
```

Algorithmus:
1. Wurzel-Paar in Generation 0 (Geburtsjahr ~1850).
2. Für ~7 Generationen abwärts: jedes Paar bekommt 2–4 Kinder, ~80% heiraten einen synthetischen Partner.
3. Ergebnis: ~200 Personen, ~80 Familien, deterministisch via fester Seed.
4. GEDCOM-5.5.1-Output.

Pool-Quellen für Vor-/Nachnamen: Public-Domain-Listen, im Image als `installer/demo_tree/data/{given_names,surnames}.json` gebakt.

### Import-Flow

```
1. Wizard wartet auf nginx-Healthcheck (= phpfpm + DB ready).
2. Wizard wartet auf Bootstrap-Marker (/var/www/html/.webtrees-bootstrapped).
3. docker compose cp /work/demo.ged phpfpm:/tmp/demo.ged
4. docker compose exec phpfpm su www-data -s /bin/sh -c \
     "php /var/www/html/index.php tree --create demo"
5. docker compose exec phpfpm su www-data -s /bin/sh -c \
     "php /var/www/html/index.php tree-import demo /tmp/demo.ged"
6. docker compose exec phpfpm rm /tmp/demo.ged
```

`tree --create` und `tree-import` sind als funktionierend bekannt (Webtrees-CLI).

## CI

### Workflow-Struktur

Ein erweitertes `.github/workflows/build.yml` mit fünf parallelen Jobs + Smoke-Test:

```
matrix         → liest versions.json, nginx-version.json, installer-version.json
build-php      → für jeden versions.json-Eintrag: webtrees-php
build-php-full → für jeden versions.json-Eintrag: webtrees-php-full
build-nginx    → einmal: webtrees-nginx (entkoppelt)
build-installer→ einmal: webtrees-installer (entkoppelt)
smoke-test     → für jeden versions.json-Eintrag: Wizard-Aufruf + curl /
```

### Versions-Manifeste

| Datei | Inhalt | Trigger |
|---|---|---|
| `dev/versions.json` | Matrix für `webtrees-php`(`-full`) | versions.json-Änderung |
| `dev/nginx-version.json` (neu) | `{ "nginx_base": "1.28", "config_revision": 1 }` | `rootfs/etc/nginx/**` oder Manifest-Änderung (paths-filter) |
| `dev/installer-version.json` (neu) | `{ "version": "1.0.0" }` | `installer/**` oder Manifest-Änderung (paths-filter) |

### Tag-Strategie (Cluster A)

- `webtrees-php:<wt>-php<x>` + Extra-Tags aus `versions.json[].tags` (heute schon).
- `webtrees-php-full:<wt>-php<x>` + analoge Extra-Tags.
- `webtrees-nginx:<nginx>-r<rev>` + `:latest`.
- `webtrees-installer:<rev>` + `:latest`.

Mehrere parallele `latest-*`-Spuren (`latest-legacy`, `latest-beta`) bleiben Cluster C.

### Smoke-Test

Matrix-Job über `versions.json`-Einträge × Editionen (`core`, `full`). Pro Kombination:

Die Smoke-Test-Matrix lebt in `.github/workflows/build.yml` (Job `smoke-test`). Sie deckt drei Editionen pro PHP-Version ab:

| Edition | Wizard-Aufruf | Probe |
|---|---|---|
| `core` | `--edition core --no-admin --no-up --proxy standalone --port 18080` | Stack hoch, `curl localhost:18080` enthält `webtrees`, dann teardown. |
| `full` | `--edition full --no-admin --no-up --proxy standalone --port 18080` | wie `core`. |
| `demo` | `--edition full --demo --demo-seed 42 --no-admin --no-up --proxy standalone --port 18080` | `demo.ged` existiert + `^2 VERS 5.5.1$` matched; Stack-Hochfahren entfällt. |

Die Folge-Steps (`Up stack`, `Wait for nginx healthy`, `Probe HTTP`, `Tear down`) springen bei `EDITION=demo` per Guard früh raus, weil die `demo`-Zelle den Stack nicht hochfährt (Demo-Import braucht eine laufende DB und gehört in den lokalen E2E-Run).

Smoke-Test deckt **nicht** ab: Demo-Tree-Import, Admin-Bootstrap (separater E2E-Test, wird ergänzt sobald Pfad A validiert ist).

### Was nicht im Cluster-A-Scope

Bleibt für Cluster C: Docker-Hub-Mirror, Nightly-Build-Workflow, PHP-Version-Polling, Fehler-Notification (Mail/Slack), zusätzliche `latest-*`-Tag-Spuren.

## Doku

### Drei Dateien (Phase 2b liefert nur die erste)

| Pfad | Zielgruppe | Umfang |
|---|---|---|
| `README.md` | Self-Hoster | ~100 Zeilen |
| `docs/developing.md` | Modul-Entwickler | heutige README, ohne Self-Host-Quickstart, ohne `make enable-dev-mode` |
| `docs/customizing.md` | beide | ~80 Zeilen, `compose.override.yaml`-Patterns |

**Phase 2b liefert nur `README.md`.** `docs/developing.md` und `docs/customizing.md` sind Phase-3-Liefergegenstände; bis dahin verweist die README in einer kurzen Notiz auf den künftigen Customising-Guide und enthält am Ende eine sechszeilige `--mode dev`-Invocation für Modul-Entwickler.

### `README.md`-Gliederung

```
1. Quickstart (ein docker run)
2. Editionen-Übersicht (Core / Full / Full+Demo)
3. Modi-Übersicht (Standalone / Traefik)
4. Was der Wizard schreibt
5. Anpassungen → docs/customizing.md
6. Update auf neue Version:
   - Wizard erneut laufen → schreibt neues compose.yaml mit neuen Image-Tags
   - docker compose pull
   - app:-Volume wipen (docker compose down && docker volume rm webtrees_app)
   - docker compose up -d
   database: und media: bleiben unberührt; alle User-Daten und Tree-Inhalte
   überleben den Upgrade. config.ini.php wird beim ersten Boot vom
   Admin-Bootstrap-Hook neu geschrieben (falls aktiv).
7. Backup (db-dump + Volume-Tarball)
8. FAQ / Troubleshooting (~15 Zeilen)
9. Link auf docs/developing.md
```

### `docs/customizing.md`-Snippets

PHP-Limits anheben, eigene nginx-Snippets, externe DB, eigene Module dazustellen — alles als copy-paste-fertige `compose.override.yaml`-Beispiele.

### Sprache

Englisch in `README.md` und `docs/`. Konsistent mit OCI-Labels und Repo-Default.

## Tests

| Ebene | Was | Wo |
|---|---|---|
| Unit | Wizard-Logik (Validation, Defaults, Choice) | `installer/tests/` mit pytest |
| Template-Render | Jinja-Templates rendern ohne Exception, Output ist valid YAML, Image-Tags stimmen | pytest-Matrix über alle Edition×Modus×Proxy-Kombinationen |
| GEDCOM | Deterministisch via Seed, GEDCOM-5.5.1-konform | pytest + `python-gedcom` |
| Entrypoint | Init-Service idempotent, Admin-Bootstrap Marker-getrieben | bash-Tests unter `tests/`, ergänzt zu heutigem `tests/test-entrypoint.sh` |
| Smoke | Stack hochfahren via Wizard, curl /, Healthcheck | GitHub Actions |
| E2E (Admin+Demo) | Wizard mit `--edition demo --admin`, Login + Tree-Visit | GitHub Actions, sobald Pfad A validiert |

## Fehlerbehandlung

Wizard-Edge-Cases sind im Abschnitt "Wizard-Flow → Edge-Cases" abgedeckt.

Init-Service: Bei zerstörtem `secrets:`-Volume regeneriert er Passwörter; die DB im `database:`-Volume kennt aber das alte Passwort. Doku empfiehlt: secrets-Volume nicht isoliert löschen — entweder beide oder DB-Passwort manuell zurücksetzen.

Bootstrap-Hook: Marker-File-getrieben, Retry-bei-Fehler durch fehlenden Marker beim nächsten Container-Start. Toleranz für "User existiert schon".

Demo-Import: bei vorhandenem `demo`-Tree fragt Wizard nach skip/overwrite/abbruch. Bei Parse-Error wird die CLI-Ausgabe gezeigt und der Stack bleibt laufen.

## Offene Implementations-Punkte (Plan-Phase)

1. **`magicsunday/webtrees-module-installer-plugin` als transitive Composer-Dependency**: Die Magic-Sunday-Module könnten das Plugin in ihrem eigenen `require` listen. In `setup/composer-full.json` muss verifiziert werden, ob ein `replace` oder `provide` nötig ist, um das Plugin auszuschließen.
2. **Headless-Webtrees-Setup via Pfad A** muss prototypisch validiert werden: Existiert ein `migrate`-Command in der Webtrees-CLI? Welche Reihenfolge zwischen `migrate` und `user --create` ist korrekt? Was passiert, wenn `config.ini.php` korrekt ist, aber die DB schema-leer?
3. **Port-Konflikt-Check via temporären Alpine-Container** in Edge-Cases (Docker-Daemon im Restricted-Mode, kein `--network host` erlaubt): wenn der Check selbst failt, downgraden zu "Warnung statt Live-Check" — nicht Hard-Stop.
4. **GEDCOM-Generator-Bibliothek**: `gedcom-faker`, `python-gedcom`, oder Eigenbau (~150 LOC). Plan-Phase entscheidet nach Schema-Konformität und Wartung.

## Was nicht in Cluster A

Bewusst verschoben in Cluster B (Image-Flavors) oder C (CI/Release-Pipeline):

- SQLite-Variante (kein `db:`-Container)
- Standalone HTTPS mit Cert-Mount oder Self-Signed-Generator
- Docker-Hub-Mirror
- Nightly-Builds
- PHP-Version-Polling
- Mehrere `latest-*`-Tag-Spuren
- Fehler-Notifications bei Build-/Smoke-Fail
- Multi-Tenant-Setup-Doku
- Webtrees-Upgrade-Pfad-Doku (bleibt User-Verantwortung mit Hinweis)

## Migration

Keine Backward-Compat. `scripts/setup.sh`, `make enable-dev-mode`, `make disable-dev-mode`, `make dev-mode-status` werden gelöscht. Bleibende Make-Targets: `up`, `down`, `restart`, `build`, `bash`, `bash-root`, `modules-shell`, `install`, `apply-config`, `composer-install`, `composer-update`, `lang`, `release-*`.

## Discovery findings (2026-05-11)

Validiert via isoliertem `webtrees-discover`-Stack auf Port 19199 mit webtrees 2.2.6, Bundled-Image `ghcr.io/magicsunday/webtrees/php:8.5`, MariaDB 11.7, leerer Schema-DB.

### Webtrees-CLI: Layout

In dieser Repo-Variante (webtrees als Composer-Dependency, nicht als Repo-Root) liegt der Symfony-Console-Launcher unter `/var/www/html/public/index.php`, NICHT `/var/www/html/index.php`. Letzteres existiert nicht; webtrees' eigenes `vendor/fisharebest/webtrees/index.php` referenziert einen nested `vendor/autoload.php`, der hier fehlt. Der Memo-Eintrag „Webtrees CLI: `php /var/www/html/index.php`" gilt für die Upstream-Repo-Variante, nicht für unser Image-Layout.

Korrekte CLI-Aufrufform für Bootstrap-Hook und Doku:
```sh
php /var/www/html/public/index.php <command> [...]
```

Verfügbare Commands (vollständige Liste aus `… list`):
- `compile-po-files`, `config-ini`
- `site-offline`, `site-online`, `site-setting`
- `tree`, `tree-export`, `tree-import`, `tree-list`, `tree-setting`
- `user`, `user-list`, `user-setting`, `user-tree-setting`

### Befund 1: Migrate-Command existiert NICHT

Es gibt KEINEN `migrate`/`db:migrate`/`database:migrate`/`schema:update`/`webtrees:install`-Command — die `COMMANDS`-Liste in `app/Cli/Console.php` ist abschließend (14 Einträge). Schema-Migration läuft ausschließlich über die HTTP-Middleware `Fisharebest\Webtrees\Http\Middleware\UpdateDatabaseSchema`, die bei JEDEM HTTP-Request unconditionally `MigrationService::updateSchema(\Fisharebest\Webtrees\Schema::class, 'WT_SCHEMA_VERSION', Webtrees::SCHEMA_VERSION)` aufruft. Kein CLI-Command triggert diese Migration.

**Konsequenz für Task 9**: Der Bootstrap-Hook muss einen HTTP-Roundtrip einbauen, BEVOR irgendein User/Tree-CLI-Command läuft — sonst scheitert z. B. `user --create` mit `SQLSTATE[42S02]: Table 'webtrees.wt_user' doesn't exist` (verifiziert).

Ein leerer GET liefert ein 404 (kein `base_url`-Match), aber die Migration läuft trotzdem durch — bestätigt: leere DB → ein einziger `curl http://localhost/` → 31 `wt_*`-Tabellen existieren.

### Befund 2: User-Create existiert, aber `--admin` ist NICHT direkt am `user`-Command

Exakte Signatur (aus `user --help`):
```
user [--create] [--delete] [--real-name REAL-NAME] [--email EMAIL] [--password PASSWORD] [--] <user-name>
```

Es gibt KEIN `--admin`-Flag. Admin-Rolle wird als User-Preference `canadmin=1` gesetzt (Konstante `UserInterface::PREF_IS_ADMINISTRATOR`, geprüft in `Auth.php` und `UserEditAction.php`). Im CLI ist das eine separate `user-setting`-Invocation.

Hinweis: das Flag heißt `--real-name` (mit Bindestrich), nicht `--realname`.

### Befund 3: `config-ini` schreibt die Config robust

`config-ini`-Command schreibt `data/config.ini.php` direkt und verifiziert die DB-Verbindung in einem Schritt. Erfolgsausgabe: `[OK] Database connection successful`. Vorhandene Werte werden nur überschrieben, wenn die jeweilige Option mitgegeben wird (z. B. `config-ini --base-url=…` ändert nur `base_url`).

Modernes Format (von `config-ini` geschrieben):
```ini
; <?php return; ?> DO NOT DELETE THIS LINE
dbtype = "mysql"
dbhost = "db"
…
```
Das ältere Template-Format `; <?php exit; ?> DO NOT DELETE THIS LINE` (aus `setup/vendor/fisharebest/webtrees/data/config.ini.php`) wird von webtrees ebenfalls akzeptiert (`parse_ini_file` ignoriert die PHP-Wrapper-Zeile in beiden Varianten).

**Empfehlung**: Bootstrap-Hook ruft `config-ini` auf — robuster und einheitlicher als manuelles `sed`-Templating des Repo-Setup-Files.

### Verifizierte Bootstrap-Reihenfolge (End-to-End grün)

Gegen leere MariaDB-DB + frisch-seeded `/var/www/html`:

```sh
# 1. Schreibe config.ini.php und verifiziere DB-Connect.
php /var/www/html/public/index.php config-ini \
  --dbtype=mysql --dbhost=db --dbport=3306 \
  --dbname=webtrees --dbuser=webtrees --dbpass="${MARIADB_PASSWORD}" \
  --tblpfx=wt_ --base-url="${BASE_URL}"

# 2. Trigger Schema-Migration über HTTP-Selbstaufruf.
#    Antwort-Status ist egal (200/404/301 alle OK); UpdateDatabaseSchema-Middleware
#    läuft im Front-Controller VOR dem Routing.
curl -fsSL -o /dev/null "${BASE_URL}/" || true

# 3. Admin-User anlegen.
php /var/www/html/public/index.php user --create admin \
  --real-name="${ADMIN_REAL_NAME:-Administrator}" \
  --email="${ADMIN_EMAIL}" \
  --password="${ADMIN_PASSWORD}"

# 4. Admin-Rolle setzen.
php /var/www/html/public/index.php user-setting admin canadmin 1

# 5. (Optional) Demo-Tree anlegen.
php /var/www/html/public/index.php tree --create "${TREE_NAME}" --title="${TREE_TITLE}"
php /var/www/html/public/index.php tree-import "${TREE_NAME}" --gedcom-file=/var/www/html/data/demo.ged
```

`user-list` zeigt anschließend `admin | … | Admin yes` — Admin-Login auf `/login` funktioniert (CSRF-Token im HTML verifiziert, Login programmatisch nicht durchgespielt; Cookie-Issue ist erwartet, Bootstrap-Erfolg sichtbar).

### Quirks für Task-9-Implementierung

1. **Pfad**: NICHT `/var/www/html/index.php`. `/var/www/html/public/index.php` ist der einzige funktionierende CLI-Launcher in unserem Image-Layout. Falls das Image-Layout sich später ändert (z. B. webtrees-Root als Repo-Root), neu validieren.
2. **HTTP-Trigger gegen Selbstaufruf**: `curl http://nginx/` aus dem `phpfpm`-Container heraus erreicht den nginx-Service über das Compose-Default-Netz — `BASE_URL=http://nginx` (interne Service-Auflösung) ist robuster als `localhost`, wenn nginx auf einem anderen Host-Port published wird. Alternative: `php -r 'require "/var/www/html/vendor/autoload.php"; …'` mit direktem `MigrationService`-Aufruf, dann brauchts kein laufendes nginx. Empfehlung: HTTP-Variante, weil sie das echte Front-Controller-Bootstrap durchläuft und damit auch eventuelle Modul-Init-Pfade abdeckt.
3. **Idempotenz**: `user --create admin …` liefert bei zweitem Aufruf einen Fehler. Bootstrap-Hook muss vor `user --create` mittels `user-list` (oder Marker-File) prüfen.
4. **`canadmin=1` setzt nur ein Preference**, kein User-Role-Wechsel — falls die Logik in webtrees später auf rollen-basierte Berechtigungen umgestellt wird, neu validieren.
5. **`WEBTREES_VERSION` muss im phpfpm-Env gesetzt sein**, sonst weigert sich `docker-entrypoint.sh` zu seeden (verifiziert: `WEBTREES_AUTO_SEED=true but WEBTREES_VERSION is empty — refusing to seed without a version identifier`). In `compose.yaml` aktuell von `.env` durchgeschoben, dort aber im Repo-Default leer — Out-of-the-Box-Self-Host-Setup muss `WEBTREES_VERSION` als Pflicht-Variable im neuen `.env`-Template setzen oder im Compose mit einem Default belegen.
6. **`ENFORCE_HTTPS=TRUE` + kein TLS** führt zu `301 → https`, was bei reinem HTTP-Self-Host-Trigger via curl scheitert. Bootstrap-Hook muss entweder `-k` oder eine Selbst-IP-Reverse-Schiene fahren. Cleaner: Schema-Migration NICHT über curl, sondern via PHP-One-Liner (siehe Quirk 2, Alternative).
7. **Eingebauter `db`-Service vs. external**: Im aktuellen `.env` ist `COMPOSE_FILE` standardmäßig mit `compose.external.yaml` verlinkt, was den lokalen `db`-Service zum No-Op-Container macht. Out-of-the-Box-Setup muss das Default-Compose-Profile umstellen (Cluster A: `compose.yaml:compose.publish.yaml` als Default).

### Empfehlung für den Bootstrap-Hook (ersetzt `── PLACEHOLDER ──` in Task 9)

```sh
# Migrate-Schritt: direkter Aufruf der MigrationService aus dem CLI heraus.
# Vermeidet HTTP-Selbstaufruf-Problematik (HTTPS-Redirect, Container-DNS).
php -d display_errors=0 -r '
require "/var/www/html/vendor/autoload.php";
use Fisharebest\Webtrees\Cli\Console;
use Fisharebest\Webtrees\Services\MigrationService;
use Fisharebest\Webtrees\Registry;
use Fisharebest\Webtrees\Webtrees;
Webtrees::new()->bootstrap();   # wires Registry::container; required
(new Console())->bootstrap();
Registry::container()->get(MigrationService::class)
  ->updateSchema("\\Fisharebest\\Webtrees\\Schema", "WT_SCHEMA_VERSION", Webtrees::SCHEMA_VERSION);
echo "schema ok\n";
'

# User-Create-Schritt:
php /var/www/html/public/index.php user --create "${ADMIN_USERNAME}" \
  --real-name="${ADMIN_REAL_NAME}" \
  --email="${ADMIN_EMAIL}" \
  --password="${ADMIN_PASSWORD}" \
&& php /var/www/html/public/index.php user-setting "${ADMIN_USERNAME}" canadmin 1
```

Der PHP-One-Liner-Migrate-Schritt ist NICHT End-to-End validiert (nur die HTTP-Variante via `curl /` ist verifiziert), aber er bildet exakt nach, was `UpdateDatabaseSchema::process()` tut. Vor Merge von Task 9 in einem isolierten Discovery-Stack durchspielen.

### Stack-Konfiguration für isolierten Discovery-Run (für künftige Validierungen)

`.env`-Diff gegenüber Repo-Default für eine saubere, parallel laufende Discovery-Box:
```env
COMPOSE_PROJECT_NAME=webtrees-discover
COMPOSE_FILE=compose.yaml:compose.publish.yaml   # KEIN compose.external.yaml
APP_PORT=19199                                   # frei wählen
ENFORCE_HTTPS=FALSE                              # sonst 301→HTTPS
MARIADB_HOST=db                                  # interner Compose-Service
WEBTREES_VERSION=2.2.6                           # PFLICHT (sonst no-seed)
```

Tear-down: `docker compose --env-file .env down -v` löscht nur die `webtrees-discover_*`-Volumes — die Live-`webtrees`-Volumes bleiben unangetastet.
