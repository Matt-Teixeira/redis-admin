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

## Setup

```bash
git clone git@github.com:Matt-Teixeira/redis-admin.git
cd redis-admin
docker compose up -d
```

Then check health:

```bash
docker compose ps
docker compose logs redis-PROD
```

## Connecting

From the host (via `docker exec`):

```bash
docker exec -it redis-PROD      redis-cli
docker exec -it redis-STAGING   redis-cli
docker exec -it redis_dev-0-4   redis-cli
docker exec -it redis_dev-0-5   redis-cli
```

From another container attached to `redis_net`, use the container name or static IP as the host (port `6379` in all cases):

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

## Known issues

- **No AUTH.** None of the instances have `requirepass` set. The `REDIS_PROD_PASSWORD` / `REDIS_STAGING_PASSWORD` entries in `.env` are currently unused — they'll only take effect once `requirepass` is uncommented in the config files (and every consuming app's Redis client config gains the password). Deferred hardening item; instances are reachable only via `redis_net` and published host ports.
