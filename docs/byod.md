# Bring-your-own-data

The standard install path is "wizard renders compose.yaml, compose
pulls images, init container generates a random DB password, MariaDB
starts up fresh and webtrees creates an empty schema". For operators
who already have webtrees data (an existing tree, media files, a
production MariaDB hosting other apps), the BYOD flags let the
rendered stack plug into that data without a dump-and-reimport cycle.

Three independent BYOD patterns are supported; pick exactly one per
install (the wizard rejects combinations that would collide):

| Flag | Use case |
|---|---|
| `--use-external-db` | Connect phpfpm to an existing MariaDB / MySQL on another host. Bundled `db` service is dropped. |
| `--db-data-path` / `--media-path` | Bind-mount MariaDB's data dir and/or webtrees' media dir to host paths. Useful when the data is on a specific filesystem or needs to be visible to other tools. |
| `--reuse-volumes <project>` | Re-attach to another compose project's `<project>_database` + `<project>_media` named volumes via `external: true`. Useful when re-installing into a sibling directory while preserving the tree. |

## External database

Run webtrees against an existing MariaDB / MySQL server — a sibling
docker-compose service, a managed database, a bare-metal VM, a cloud
RDS instance. The wizard drops the bundled `db` service entirely and
points phpfpm at the operator's host.

### Prerequisites

| Requirement | Why |
|---|---|
| External MariaDB / MySQL server reachable from the docker host on a known port | The wizard probes `host:port` via TCP-connect before rendering compose; an unreachable target fails fast with an operator-actionable message instead of a phpfpm crash loop. |
| A pre-created database the wizard can write to | The wizard does not run `CREATE DATABASE`. Create the database on the external server (default name `webtrees`) before running the installer. |
| A user with the right grants on that database | Webtrees needs `SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX`. The exact statement is in the snippet below. |
| A file on the install host containing only the user's password | The wizard bind-mounts the file read-only into the phpfpm container at `/secrets/external_db_password`. No trailing newline. Mode 0400 recommended. |

Example external-server bootstrap (run once, on the MariaDB server):

```sql
CREATE DATABASE webtrees CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'webtrees'@'%' IDENTIFIED BY '<random-password>';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX
    ON webtrees.* TO 'webtrees'@'%';
FLUSH PRIVILEGES;
```

Replace `'@'%'` with a more restrictive host filter when you can —
the docker bridge's CIDR (`172.16.0.0/12` by default) covers every
container on the same host.

### Install

Write the password to a file on the install host first:

```bash
umask 077
printf '%s' '<random-password>' > /etc/webtrees/db_password
chmod 0400 /etc/webtrees/db_password
```

Then run the installer with the five `--external-db-*` flags:

```bash
./install \
    --proxy standalone --port 28080 \
    --use-external-db \
    --external-db-host db.internal.example.org \
    --external-db-port 3306 \
    --external-db-name webtrees \
    --external-db-user webtrees \
    --external-db-password-file /etc/webtrees/db_password
```

Defaults: `--external-db-port 3306`, `--external-db-name webtrees`,
`--external-db-user webtrees` — pass only the values that differ.
`--external-db-host` and `--external-db-password-file` are required.

### What the wizard renders

- `compose.yaml` — the `db:` service is dropped. The bundled
  `database` volume is dropped. phpfpm depends only on the `init`
  container (for the bootstrap secrets volume), and its environment
  reads `MARIADB_HOST / PORT / USER / PASSWORD_FILE / DATABASE` from
  the `.env` file via `${EXTERNAL_DB_*}` substitutions.
- `.env` — adds `EXTERNAL_DB_HOST / PORT / NAME / USER /
  PASSWORD_FILE` keys carrying the values you passed on the CLI.
- The password file you pointed `--external-db-password-file` at is
  bind-mounted read-only into phpfpm at `/secrets/external_db_password`.

### First start

```bash
docker compose up -d
```

The phpfpm container's entrypoint reads the password from
`/secrets/external_db_password`, connects to the external host on the
configured port, runs the webtrees schema migration against the
pre-created database, and (if `--admin-bootstrap` was passed)
creates the initial admin user.

### Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `External DB host '<name>' does not resolve` | DNS / hostname typo | Pass `--external-db-host` with a name your docker host can resolve, or an IP. |
| `External DB <host>:<port> did not answer within 5s` | Firewall, listener bound to the wrong interface, or service not running | `nc -zv <host> <port>` from the docker host to confirm. |
| `External DB <host>:<port> refused the connection` | Wrong port, or service bound only to localhost / a different network | Re-check the external server's `bind-address` and `port`. |
| `--external-db-password-file path does not exist` | Typo in path, or running the installer from a directory that doesn't share the file | Use an absolute path; verify with `ls -l`. |
| `--external-db-password-file is empty` | File was created but the password was never written, or trailing-newline-only | `cat <path> \| wc -c` — must be > 0. Re-write without a trailing newline. |
| phpfpm logs `Access denied for user 'webtrees'@'<host>'` | Password wrong, or user not granted from this host | Re-check the password file; re-run the `GRANT` snippet with the actual host filter. |
| phpfpm logs `Unknown database 'webtrees'` | Database not pre-created | Run the `CREATE DATABASE` line above on the external server, then `docker compose restart phpfpm`. |

### Switching back to the bundled database

There is no in-place switch. The two paths render structurally
different `compose.yaml` files (the `db:` service comes back, the
bundled `database` volume re-appears). Re-run the installer without
`--use-external-db` in a fresh directory; if you need to migrate
data, dump from the external DB with `mysqldump` and restore into
the new bundled `db` service.

## Host-path bind-mount

Replace either named volume with a host-path bind-mount.

```bash
./install \
    --proxy standalone --port 28080 \
    --db-data-path /srv/webtrees/mariadb \
    --media-path /srv/webtrees/media
```

Both flags are independent; pass either or both. The wizard refuses
fast if the path is relative, missing, or not a directory.

### Permissions

- `--db-data-path`: the MariaDB image runs as its own `mysql` user.
  On first start it expects an empty directory or a pre-populated
  one from a compatible version. Pre-create the directory and chown
  it to the image's mysql uid — read the uid back with
  `docker run --rm <mariadb-image> id mysql` if you are unsure.
- `--media-path`: the php-fpm container runs webtrees as its own
  `www-data` user. Pre-create the directory and chown it to that
  uid; read it back with `docker run --rm <php-image> id www-data`
  on the exact image tag the wizard rendered (the uid differs
  between Debian-based and Alpine-based php-fpm images).

`--db-data-path` is incompatible with `--use-external-db` — the
bundled `db` service is dropped, so there is nowhere to bind-mount
into. `--media-path` works with both modes.

## Reuse named volumes from an existing project

Re-attach to an existing compose project's `<project>_database` and
`<project>_media` named volumes. Useful when re-installing webtrees
in a sibling directory without losing the tree.

```bash
./install \
    --proxy standalone --port 28080 \
    --reuse-volumes wt_old
```

The wizard verifies both target volumes exist via `docker volume
inspect` before rendering — `--reuse-volumes wt_old` requires
`wt_old_database` AND `wt_old_media` to be present. Confirm with
`docker volume ls | grep wt_old_`.

`--reuse-volumes` is mutually exclusive with the other two patterns
(`--use-external-db`, `--db-data-path`, `--media-path`). Operators
who need to mix shapes (e.g. reuse media but use a fresh DB) layer
the override manually via `compose.override.yaml`.
