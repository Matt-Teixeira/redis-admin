# Redis Admin Environment

This repository packages a repeatable Redis environment for production, staging, and two development slices using Docker Compose. Each container runs the official `redis:7-alpine` image with a dedicated configuration file under `conf/` and persistent storage managed through named Docker volumes.

## Prerequisites
- Docker Engine 20.10+ and Docker Compose plugin v2+ installed on your workstation.
- Access to a shell with permission to run Docker commands.

## Configure Environment Variables
1. Copy the provided `.env` file if you need a personal variant (e.g. `.env.local`) and adjust values as needed.
2. Customize the IP/subnet values (`REDIS_SUBNET`, `REDIS_*_IP`) to fit your local network if the defaults conflict.
3. Update the exposed host ports (`REDIS_*_PORT`) if the defaults 6379–6382 are already in use.
4. Set `REDIS_PASSWORD` if you require Redis AUTH; leave it empty to disable authentication.

> Docker Compose automatically loads the `.env` file in the project root, so no extra export step is required.

## Review Redis Configuration
- Each service mounts a corresponding file (`conf/prod.conf`, `conf/staging.conf`, `conf/dev04.conf`, `conf/dev05.conf`).
- Adjust persistence, maxmemory, ACLs, or other Redis settings inside those files before launching containers.

## Create and Start the Containers
```bash
docker compose up -d
```
- Docker Compose provisions the custom bridge network, assigns static IPs, and creates the named volumes (`prod_data`, `staging_data`, `dev04_data`, `dev05_data`).
- The `-d` flag runs the containers in detached mode so your shell remains free.

## Verify Container Health
```bash
docker compose ps
docker compose logs redis-PROD   # replace with any service name
```
- Health checks rely on `redis-cli ping`; if you configured a password, ensure `REDIS_PASSWORD` is set before inspecting logs.

## Connect to Redis
- From the Docker host: `redis-cli -h 127.0.0.1 -p <port>` using the host ports defined in `.env`.
- From another container on the `redis_net` bridge: connect directly to the service name (e.g. `redis-PROD`) on port 6379.
- Include `-a "$REDIS_PASSWORD"` in `redis-cli` commands when authentication is enabled.

## Stop and Clean Up
```bash
docker compose down            # stops services but preserves volumes
docker compose down -v         # stops services and removes named volumes (data loss)
```
- Use the volume removal variant only when you intentionally want to discard stored data.
