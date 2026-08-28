# CLAUDE.md — redis-admin

> **Migrated to the fleet dev/release paradigm 2026-08-27** (spec:
> `data_acquisition/docs/migration_CLAUDE.md`; admin-repo precedent: `pg_manage_v2`,
> 2026-08-26). Release `7bd34e1`, verified: two clean cron cycles of the consuming
> apps and the 2026-08-28 nightly backup line (`OK ... redis=4 instances`).
>
> **The editable clone is `~/apps/redis-admin`; `/opt/apps/redis-admin` is build
> output produced only by `build-release.sh` — not a git checkout.**
>
> **Shape note:** this is an **admin/infra repo** — four long-running Redis
> containers on stock `redis:7-alpine`, no app code, no image build, no schedule,
> no run record. Only part of the paradigm applies — see *Paradigm application*.

**redis-admin** owns the four Redis instances on this server family
(`redis-PROD`, `redis-STAGING`, `redis_dev-0-4`, `redis_dev-0-5`): their compose
runtime definition, per-instance configs, the auth activation/verification script,
and the kernel host-setup files. `README.md` is the operational manual (setup,
connecting, lifecycle, auth); this file carries the conventions and the hazards.

Consumers (server doc STEP 3): `redis_dev-0-4` → the four job apps' live
acquisition state (data_acquisition, hhm_rpp_ge/philips/siemens);
`redis-STAGING` → odd-jobs (Jonathan); `redis-PROD` → none currently;
`redis_dev-0-5` → spare. Nightly RDB backups of all four are owned by
`pg_manage_v2/scripts/backup.sh`, not this repo.

---

## ☠️ THE headline hazard: never run compose lifecycle commands from the dev clone

The dev clone and the release copy resolve to the **same compose project**
(default project name = directory name = `redis-admin`), the services pin fixed
`container_name`s, and the static IPs exist once. Therefore `docker compose up`
/ `down` / `restart` run from `~/apps/redis-admin` does not create a "dev
instance" — it **operates on the four production containers** and would re-point
their config bind mounts at the dev clone's files.

- Dev-side validation is deliberately **containerless**: `bash preflight-check.sh`
  and `docker compose config` (render check). Nothing else.
- Every compose lifecycle command runs from `/opt/apps/redis-admin` only.
- There is no safe dev-instance variant without forking names/IPs — out of scope
  on purpose; the dev instances (`redis_dev-0-4/5`) already exist as services.

## Paradigm application (what applies, what is skipped)

Applies (adopted 2026-08-27):

- **Dev/release split**: editable clone at `~/apps/redis-admin`;
  `/opt/apps/redis-admin` is build output produced only by `build-release.sh`
  (clean-tree guard above the wipe, `#RELEASE:` transform machinery (no keys
  today), `RELEASE_SHA` stamp, chown `svc:docker`).
- **Release provenance**: `build-release.sh` stamps `RELEASE_SHA` into the
  deployed `.env`; the compose file carries it onto every container as the label
  `com.redis-admin.release_sha` (`${RELEASE_SHA:-dev-tree}` — fails safe to
  `dev-tree` in a dev clone). The container **is** the run for a service app, so
  `docker inspect` answers "which release created this container". The label
  updates only when a container is recreated — after a release, running
  containers carry the previous SHA until the apply step (see *Release flow*).
- **`.env.example`** as the tracked record of required keys.
- **`preflight-check.sh`** — read-only, secret-safe checks (auth verified from
  *inside* the containers; the password never leaves them). Zero warnings is the
  standard.

Skipped, deliberately (admin/infra shape — nothing here is a defect):

- **Fleet Dockerfile / entrypoint.sh / gosu / `<app>:${USER_ID}` image tags** —
  stock `redis:7-alpine`; redis runs as the image's own uid 999. No image build
  means no `build.sh` and no svc-HOME dance in the release script.
- **`${LOG_DIR}` mount / `/opt/run-logs` / vendored logger / `util.app_run_logs`**
  — no job runs exist; container logs are already capped in the tracked compose
  (json-file 10m×3, OPS-02).
- **Cron entries / cron hardening** — this app has no schedule. The nightly
  backup that covers it belongs to pg_manage_v2.
- **run_outcome/v1 + SIGTERM handlers** — redis-server's own signal handling +
  AOF persistence is the contract.
- **Rotation registration** — already listed in `rotate-envs-20260817.sh` and
  deliberately inert: this `.env` holds no credentials. This repo *owns* the
  Redis secret (`/opt/resources/secrets/redis_auth.conf`); consumers get it via
  `scripts/activate_redis_auth.sh`.

## Release flow (a service app releases in two steps)

```bash
# 1. RELEASE — from the dev clone; refuses on a dirty tree.
cd ~/apps/redis-admin && bash build-release.sh
#    Mirrors the tree to /opt/apps/redis-admin, stamps RELEASE_SHA.
#    Touches NO container: all four keep running the pre-release config.

# 2. APPLY — from the RELEASE COPY, one instance at a time, in a quiet cron window.
cd /opt/apps/redis-admin
docker compose up -d redis_dev-0-5   # spare first
docker compose up -d redis-PROD      # no consumers
docker compose up -d redis-STAGING   # odd-jobs — coordinate with Jonathan
docker compose up -d redis_dev-0-4   # busiest last: four job apps' live cursors
```

Apply notes:

- **Quiet windows** (from the consuming apps' cron cadences): ~:02–:08 and
  ~:26–:29 past each half-hour. The :15–:22 and :45–:52 stretches are
  wall-to-wall job starts — never restart `redis_dev-0-4` there.
- Each recreate is seconds; AOF + named volumes mean no data loss. A job tick
  that lands exactly in a restart fails once and self-heals next tick
  (`flock -n` skips; cursors advance only after successful insert).
- Capture `DBSIZE` per instance before/after an apply (the
  `activate_redis_auth.sh` precedent) — unchanged counts are the success check.
- `docker compose up -d` recreates only services whose compose config changed.
  **Changed *contents* of a bind-mounted config file do not trigger a recreate**
  — force it per instance with `docker compose up -d --force-recreate <svc>`
  (or `docker compose restart <svc>`, which also re-reads the config file).

## Known warts (kept deliberately — owner decisions 2026-08-26/27)

- **`docker compose down -v` destroys all four datasets.** It stays documented in
  README's lifecycle section without ceremony (owner: keep as-is). Volumes are
  project-named (`redis-admin_*_data`) and survive everything except `-v`.
  The nightly RDBs under `/opt/resources/backups/redis/` are the recovery path.
- **The `PROD` branch is stale** — none of the August auth work is on it, and
  local `PROD` is behind `origin/PROD`. Deferred: no PROD server exists yet
  (server doc: prod is "TBD"). Reconcile when a PROD deployment becomes real;
  until then `STAGING` is what this server runs.
- **Release wipe happens under live bind mounts.** The mirror replaces
  `config/*.config` while four running containers hold them. Running containers
  are unaffected (mounts pin the old inodes) — but a container that dies inside
  the seconds-long wipe window cannot auto-restart until the mirror completes
  (`create_host_path: false`). `build-release.sh` warns if any instance is
  unhealthy before it wipes; `docker compose up -d` afterwards repairs any
  casualty.

## Verification

```bash
bash preflight-check.sh          # zero warnings, from either copy
# Which release is each container running?
docker ps --filter name=redis --format '{{.Names}}' | xargs -I{} sh -c \
  'echo "{}: $(docker inspect {} --format "{{index .Config.Labels \"com.redis-admin.release_sha\"}}")"'
grep '^RELEASE_SHA=' /opt/apps/redis-admin/.env
```

This app writes no run record, so post-change verification reads its
**consumers'** records: `util.app_run_logs` for the job apps over the next two
cron cycles (no new NOAUTH/ECONNREFUSED-flavored errors, volumes in the normal
band), plus the next `pg_manage_v2` nightly backup line (~02:50 — its
authenticated `SAVE` against all four is itself a full auth+liveness check).
