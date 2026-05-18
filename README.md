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
- [config/](config/) — per-instance Redis config files (see "Known issues" below)
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

## Known issues

- **Custom Redis configs are not actually applied.** Compose bind-mounts `./conf/<name>.conf` into each container, but those paths don't exist as files — Docker auto-created them as empty directories. The real configs live at [config/](config/) (different folder, different extension). Redis is currently running on built-in defaults. To fix: rename `config/` → `conf/` and the files to `*.conf`, or update the mount paths in [docker-compose.yaml](docker-compose.yaml).
- **No AUTH.** None of the instances have `requirepass` set. The `REDIS_PROD_PASSWORD` / `REDIS_STAGING_PASSWORD` entries in `.env` are currently unused — they'll only take effect once the config files are loaded and `requirepass` is uncommented.
