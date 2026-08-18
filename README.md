# redis-admin

Compose-managed Redis instances for the `prod`, `staging`, and two `dev` environments. Each instance runs in its own container on a dedicated bridge network with a static IP. Ports are not published to the host — Redis is reachable only from other containers on the `redis_net` network, or via `docker exec` from the host.

## Layout

| Service          | Container         | Internal address      |
| ---------------- | ----------------- | --------------------- |
| `redis-PROD`     | `redis-PROD`      | `172.24.0.2:6379`     |
| `redis-STAGING`  | `redis-STAGING`   | `172.24.0.3:6379`     |
| `redis_dev-0-4`  | `redis_dev-0-4`   | `172.24.0.4:6379`     |
| `redis_dev-0-5`  | `redis_dev-0-5`   | `172.24.0.5:6379`     |

All containers run `redis:7-alpine` with `appendonly` persistence to a named Docker volume (`prod_data`, `staging_data`, `dev04_data`, `dev05_data`).

## Files

- [docker-compose.yaml](docker-compose.yaml) — service definitions, network, volumes
- [.env](.env) — subnet, IPs, host ports, optional passwords (not committed; see [.gitignore](.gitignore))
- [config/](config/) — per-instance Redis config files, bind-mounted into each container
- [commands.sh](commands.sh) — handy raw `docker` commands for ad-hoc start/stop/rebuild
- [scripts/activate_redis_auth.sh](scripts/activate_redis_auth.sh) — one-shot auth rollout/verification (see Auth section)
- [host-setup/](host-setup/) — kernel settings Redis needs, installed once per host:

```bash
sudo cp host-setup/90-redis.conf /etc/sysctl.d/ && sudo sysctl --system
sudo cp host-setup/disable-thp.service /etc/systemd/system/ && sudo systemctl enable --now disable-thp.service
```

Nightly RDB backups of all four instances are taken by `pg_manage_v2/scripts/backup.sh`
(the server-wide backup script), not by anything in this repo.

## Setup

**1. Create the auth secret first** (required — the compose file bind-mounts it with
`create_host_path: false`, so `up` fails loudly if it's missing). The password is
machine-generated into a root-only file; no human ever sees it:

```bash
sudo install -d -m 700 -o root -g root /opt/resources/secrets
sudo sh -c 'umask 277; printf "requirepass %s\n" "$(head -c 32 /dev/urandom | base64 | tr -d "/+=" | head -c 32)" > /opt/resources/secrets/redis_auth.conf'
sudo chown 999:root /opt/resources/secrets/redis_auth.conf   # 999 = container redis uid; the 700 root dir blocks host uid-999 (dd-agent)
sudo chmod 400 /opt/resources/secrets/redis_auth.conf
```

**2. Bring the instances up:**

```bash
git clone git@github.com:Matt-Teixeira/redis-admin.git
cd redis-admin
# create .env (subnet, per-instance IPs) — see .env section above
docker compose up -d
```

Then check health:

```bash
docker compose ps
docker compose logs redis-PROD
```

**3. Give the consuming apps the password.** Each app that talks to an auth'd
instance needs `REDIS_PW` in its untracked `.env`, with the same value as the secret
file. `/opt/resources/scripts/activate_redis_auth.sh` (run with sudo) propagates it
to the four app .envs and verifies the whole setup without echoing the value.
Order matters on a live server: the server must get its password **before** the app
.envs — a client configured with a password against a passwordless server hangs in
an infinite reconnect loop (node-redis v4, proven 2026-08-18); the reverse merely
fails fast with a clean NOAUTH error.

## Connecting

From the host (via `docker exec`). Three instances require auth (see the Auth
section); `redis-cli` never prompts for a password — it connects and then refuses
commands with `NOAUTH` until you authenticate. This form reads the password from
the file mounted inside the container without displaying it:

```bash
docker exec -it redis-PROD    sh -c 'redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning'
docker exec -it redis_dev-0-4 sh -c 'redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning'
docker exec -it redis_dev-0-5 sh -c 'redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning'

docker exec -it redis-STAGING redis-cli    # no auth (odd-jobs — see Auth section)
```

From another container attached to `redis_net`, use the container name or static IP as the host (port `6379` in all cases; for the three auth'd instances add `-a "$REDIS_PW"` or issue `AUTH <password>` after connecting):

```bash
redis-cli -h redis-PROD       # or -h 172.24.0.2
redis-cli -h redis-STAGING    # or -h 172.24.0.3
redis-cli -h redis_dev-0-4    # or -h 172.24.0.4
redis-cli -h redis_dev-0-5    # or -h 172.24.0.5
```

To attach an external app's container to this network, add to its compose file:

```yaml
networks:
  redis_net:
    external: true
    name: redis-admin_redis_net
```

## Lifecycle

```bash
docker compose up -d                  # start everything
docker compose stop                   # stop without removing
docker compose down                   # stop and remove containers (volumes kept)
docker compose down -v                # also remove data volumes (destructive)
docker compose restart redis-PROD     # restart one service
```

## Config files

Each service bind-mounts `./config/<name>.config` to `/usr/local/etc/redis/redis.conf`
using long-form volume syntax with `create_host_path: false`, so a typo'd source path
fails at `up` instead of being silently auto-created as an empty directory (Redis reads
a directory as an *empty config* and falls back to built-in defaults — this bit us:
until 2026-07-27 the mounts pointed at nonexistent `conf/*.conf` paths and all four
instances ran on defaults with AOF off).

**Enabling AOF on an instance that doesn't have it yet is order-sensitive.** If Redis
boots with `appendonly yes` and no AOF manifest in `/data`, it does **not** load
`dump.rdb` — it starts empty (verified on redis 7.4). To migrate safely:

```bash
docker exec <name> redis-cli CONFIG SET appendonly yes   # seeds AOF from live dataset
docker exec <name> redis-cli INFO persistence | grep aof_rewrite_in_progress  # wait for :0
docker compose up -d <service>                           # now safe to recreate
docker exec <name> redis-cli DBSIZE                      # compare against pre-migration count
```

## Auth (added 2026-08-18, audit REDIS-01)

Three of the four instances require a password: `redis-PROD`, `redis_dev-0-4`,
`redis_dev-0-5`. Their tracked configs end with
`include /usr/local/etc/redis/auth.conf`, which compose bind-mounts from the
root-only host file `/opt/resources/secrets/redis_auth.conf` (see Setup step 1).
The password never appears in this repo, in `.env`, or in `docker inspect` — the
authenticated healthcheck parses it inside the container.

**`redis-STAGING` deliberately has no password**: its consumer is odd-jobs, whose
Redis client has no auth support. It is still a required part of the standard
four-instance build — `docker compose up -d` always brings up all four; only the
`requirepass` include differs. Revisit its auth only with Jonathan.

Healthchecks check for a literal `PONG` because `redis-cli` exits 0 even when the
server refuses the command (e.g. NOAUTH) — exit codes alone would report a locked-out
instance as healthy. The nightly `backup.sh` applies the same rule to `SAVE`.

## Known issues

- (none currently — the former "No AUTH" item was resolved 2026-08-18; the stale
  `REDIS_*_PASSWORD` .env entries it referenced are gone from the design.)
