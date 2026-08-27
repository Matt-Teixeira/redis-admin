#!/usr/bin/env bash
# Preflight for redis-admin — validates the four Redis instances and the
# environment their compose definition actually uses.
# Fleet paradigm (data_acquisition/docs/migration_CLAUDE.md); skeleton from
# pg_manage_v2's admin-repo preflight, checks adapted to this repo's shape:
# long-running service containers, no jobs, no logger, no schedule.
#
# Every check is READ-ONLY and secret-safe: auth is verified by parsing the
# password INSIDE each container (the healthcheck/backup.sh pattern) — the
# value never reaches this shell or the terminal.
#
# A clean run reports ZERO warnings: treat a persistent warning as a bug in
# the check itself, or it trains people to ignore output. (Known transient
# exception: between a release and its rolling apply, the release_sha label
# checks WARN by design — that is the "apply pending" state, not a bug.)
# Exit codes: 0 = pass (or warnings only), 1 = critical errors found.
set -u
cd "$(dirname "$0")"

ERRORS=0; WARNINGS=0; OKS=0
ok()    { echo "  OK    $*"; OKS=$((OKS+1)); }
warn()  { echo "  WARN  $*"; WARNINGS=$((WARNINGS+1)); }
error() { echo "  ERROR $*"; ERRORS=$((ERRORS+1)); }
info()  { echo "        $*"; }
section(){ echo; echo "== $* =="; }

# Read KEY= from .env, stripping quotes, dotenv-style inline comments and
# trailing whitespace. NEVER source a fleet .env (the $$-in-URI lesson).
env_val() {
    grep "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- \
        | sed -e 's/[[:space:]]\+#.*$//' -e 's/[[:space:]]*$//' \
              -e "s/^['\"]//" -e "s/['\"]$//"
}

INSTANCES="redis-PROD redis-STAGING redis_dev-0-4 redis_dev-0-5"
AUTH_IN_CONTAINER='redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning'

# ------------------------------------------------------- 1. identity/location
section "Identity"
APP_NAME_V="$(env_val APP_NAME)"
if [ ! -f .env ]; then
    error ".env missing — copy .env.example and fill it in"
elif [ "$APP_NAME_V" != "redis-admin" ]; then
    error ".env: APP_NAME='$APP_NAME_V' (expected redis-admin) — build-release.sh derives its destination from this"
else
    ok "APP_NAME=$APP_NAME_V"
fi
for k in REDIS_SUBNET REDIS_GATEWAY REDIS_PROD_IP REDIS_STAGING_IP REDIS_DEV04_IP REDIS_DEV05_IP; do
    if [ -n "$(env_val "$k")" ]; then ok "$k set"; else error ".env: $k missing/empty — compose interpolation would fail"; fi
done
RELEASE_SHA_V="$(env_val RELEASE_SHA)"
IS_RELEASE_COPY=0
if [ "$(pwd)" = "/opt/apps/redis-admin" ]; then
    IS_RELEASE_COPY=1
    if [ -n "$RELEASE_SHA_V" ]; then
        ok "release copy: RELEASE_SHA=$RELEASE_SHA_V (stamped by build-release.sh)"
    else
        error "release copy but RELEASE_SHA missing — containers would relabel as 'dev-tree' on recreate; was build-release.sh bypassed?"
    fi
else
    if [ -n "$RELEASE_SHA_V" ]; then
        error "dev clone but RELEASE_SHA present — never set it by hand (a dev clone must render 'dev-tree')"
    else
        ok "dev clone: no RELEASE_SHA (label renders 'dev-tree')"
    fi
    info "DEV CLONE: validation here is containerless — NEVER run compose lifecycle"
    info "commands from this directory; they would operate on the four PRODUCTION"
    info "containers (same project name, fixed container_names, static IPs)."
fi

# ------------------------------------------------------------------- 2. files
section "Files"
for f in docker-compose.yaml build-release.sh .env.example scripts/activate_redis_auth.sh \
         host-setup/90-redis.conf host-setup/disable-thp.service; do
    if [ -f "$f" ]; then ok "$f present"; else error "$f missing"; fi
done
for c in prod staging dev04 dev05; do
    if [ ! -f "config/$c.config" ]; then
        error "config/$c.config missing — its container reads defaults from an empty mount (the 2026-07-27 lesson)"
    elif grep -q '^include /usr/local/etc/redis/auth.conf' "config/$c.config"; then
        ok "config/$c.config present, auth include intact"
    else
        error "config/$c.config lacks 'include /usr/local/etc/redis/auth.conf' — that instance would come up PASSWORDLESS at next recreate"
    fi
done

# ------------------------------------------------------------------ 3. docker
section "Docker"
if docker ps >/dev/null 2>&1; then ok "docker daemon reachable"; else error "docker daemon not reachable as $(id -un)"; fi
if id -nG | grep -qw docker; then ok "$(id -un) is in the docker group"; else error "$(id -un) not in docker group"; fi
if docker compose version >/dev/null 2>&1; then ok "docker compose available"; else error "docker compose not available"; fi
if docker compose config --quiet >/dev/null 2>&1; then
    ok "docker compose config renders against this .env"
else
    error "docker compose config fails — bad .env interpolation or compose syntax"
fi
if docker network inspect redis-admin_redis_net >/dev/null 2>&1; then
    ok "network redis-admin_redis_net exists"
else
    error "network redis-admin_redis_net missing — every consumer app attaches to it as external"
fi
for v in prod_data staging_data dev04_data dev05_data; do
    if docker volume inspect "redis-admin_$v" >/dev/null 2>&1; then
        ok "volume redis-admin_$v exists"
    else
        error "volume redis-admin_$v missing — that instance's dataset is gone or was never created"
    fi
done

# --------------------------------------------------------------- 4. instances
section "Instances (auth verified in-container; password never leaves it)"
for r in $INSTANCES; do
    state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$r" 2>/dev/null || echo absent)"
    if [ "$state" != "running healthy" ]; then
        error "$r is '$state' (expected running+healthy)"
        continue
    fi
    ok "$r running and healthy"

    anon="$(docker exec "$r" redis-cli PING 2>&1 || true)"
    case "$anon" in
        *NOAUTH*) ok "$r anonymous PING refused (auth is live)" ;;
        *PONG*)   error "$r anonymous PING succeeded — instance is PASSWORDLESS (auth include lost?)" ;;
        *)        error "$r anonymous PING: unexpected '$anon'" ;;
    esac

    authed="$(docker exec "$r" sh -c "$AUTH_IN_CONTAINER PING" 2>/dev/null || true)"
    if [ "$authed" = "PONG" ]; then
        ok "$r authenticated PING -> PONG"
    else
        error "$r authenticated PING failed ('$authed') — secret file vs server password mismatch?"
    fi

    if docker exec "$r" sh -c '[ -s /usr/local/etc/redis/auth.conf ]' 2>/dev/null; then
        ok "$r secret file mounted and non-empty"
    else
        error "$r secret file missing/empty inside container — check /opt/resources/secrets/redis_auth.conf mount"
    fi

    aof="$(docker exec "$r" sh -c "$AUTH_IN_CONTAINER CONFIG GET appendonly" 2>/dev/null | tail -1 || true)"
    if [ "$aof" = "yes" ]; then
        ok "$r appendonly=yes (AOF persistence live)"
    else
        error "$r appendonly='$aof' (expected yes) — running on defaults? (the empty-config-mount failure mode)"
    fi

    # Provenance label — meaningful in the release copy only. Between a
    # release and its rolling apply this WARNS by design (apply pending).
    if [ "$IS_RELEASE_COPY" = "1" ] && [ -n "$RELEASE_SHA_V" ]; then
        lbl="$(docker inspect -f '{{index .Config.Labels "com.redis-admin.release_sha"}}' "$r" 2>/dev/null || true)"
        if [ "$lbl" = "$RELEASE_SHA_V" ]; then
            ok "$r release_sha label = $lbl (matches deployed .env)"
        elif [ -z "$lbl" ]; then
            warn "$r has no release_sha label — container predates the label; apply pending (recreate in a quiet window)"
        else
            warn "$r release_sha label = '$lbl' but deployed .env says $RELEASE_SHA_V — apply pending"
        fi
    fi
done

# -------------------------------------------------------------- 5. host kernel
section "Host kernel (host-setup/)"
oc="$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo '?')"
if [ "$oc" = "1" ]; then
    ok "vm.overcommit_memory=1 (90-redis.conf applied)"
else
    error "vm.overcommit_memory=$oc (expected 1) — BGSAVE/AOF-rewrite can fail under memory pressure; install host-setup/90-redis.conf"
fi
thp="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '?')"
case "$thp" in
    *'[never]'*) ok "transparent hugepages disabled" ;;
    *) error "THP is '$thp' (expected [never]) — latency spikes + fork bloat; check disable-thp.service" ;;
esac

# ------------------------------------------------------------------ 6. backups
section "Backups (owned by pg_manage_v2, verified here as this app's safety net)"
BK=/opt/resources/backups/redis
if [ -r "$BK" ]; then
    newest="$(ls -t "$BK"/*.rdb 2>/dev/null | head -1 || true)"
    if [ -z "$newest" ]; then
        error "no RDB files in $BK — nightly backup has never run?"
    elif [ -n "$(find "$newest" -mtime -2 2>/dev/null)" ]; then
        ok "newest RDB < 48h old ($(basename "$newest"))"
    else
        error "newest RDB older than 48h ($(basename "$newest")) — check pg_manage_v2 backup.sh / its cron entry"
    fi
else
    info "$BK not readable by $(id -un) — backup freshness not checked here (see pg_manage_v2's backup.log)"
fi

# ---------------------------------------------------------------------- summary
echo
echo "== Summary: $OKS OK, $WARNINGS warnings, $ERRORS errors =="
if [ "$ERRORS" -gt 0 ]; then
    echo "   CRITICAL ERRORS FOUND — fix before relying on these instances."
    exit 1
fi
[ "$WARNINGS" -gt 0 ] && echo "   Warnings present — a clean run has ZERO (apply-pending label warnings clear after the rolling apply)."
exit 0
