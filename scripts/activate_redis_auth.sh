#!/usr/bin/env bash
# Redis auth activation (REDIS-01 follow-up). Run with sudo AFTER:
#   1. the secret file exists (see README step 1)
#   2. the redis-admin compose + config changes are applied (Claude applies pre-approved)
# Usage: sudo ./activate_redis_auth.sh
set -euo pipefail

SECRET=/opt/resources/secrets/redis_auth.conf
ADMIN=/opt/apps/redis-admin
# Both copies of a paradigm-migrated app need the password: the release copy in
# /opt/apps AND the dev clone in ~/apps (no #RELEASE: override on credentials —
# a rewrite of only one leaves the other broken until the next release). Dev
# clones that don't exist on this host are skipped by the loop below, same as
# Jonathan's apps. Absolute /home paths on purpose: this runs under sudo.
ENVS=(
  /opt/apps/data_acquisition/.env  /home/matt-teixeira/apps/data_acquisition/.env
  /opt/apps/hhm_rpp_ge/.env        /home/matt-teixeira/apps/hhm_rpp_ge/.env
  /opt/apps/hhm_rpp_philips/.env   /home/matt-teixeira/apps/hhm_rpp_philips/.env
  /opt/apps/hhm_rpp_siemens/.env   /home/matt-teixeira/apps/hhm_rpp_siemens/.env
  /opt/apps/odd-jobs/.env
  /opt/apps/mmb-rpp/.env
)
AUTHED=(redis-PROD redis-STAGING redis_dev-0-4 redis_dev-0-5)   # all four since 2026-08-19

[ -r "$SECRET" ] || { echo "FATAL: cannot read $SECRET (run with sudo, after creating it)"; exit 1; }
PW=$(awk '/^requirepass/{print $2}' "$SECRET")
[ -n "$PW" ] || { echo "FATAL: no requirepass line in $SECRET"; exit 1; }

echo "== pre-recreate key counts"
declare -A PRE
for r in "${AUTHED[@]}"; do
  PRE[$r]=$(docker exec "$r" sh -c 'redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning DBSIZE')
  echo "  $r: ${PRE[$r]}"
done

echo "== updating REDIS_PW in ${#ENVS[@]} .envs (value not echoed)"
for f in "${ENVS[@]}"; do
  # Jonathan's apps are on the list but may not be cloned on this box (mmb-rpp);
  # a missing path must not abort the rotation mid-run (envs updated, server not).
  [ -f "$f" ] || { echo "  skip $f (not present on this host)"; continue; }
  if grep -q '^REDIS_PW=' "$f"; then
    sed -i "s|^REDIS_PW=.*|REDIS_PW=$PW|" "$f"
  else
    printf '\n# Redis auth (REDIS-01 rollout 2026-08-18); value mirrors /opt/resources/secrets/redis_auth.conf\nREDIS_PW=%s\n' "$PW" >> "$f"
  fi
done

echo "== recreating changed redis services"
docker compose -f "$ADMIN/docker-compose.yaml" up -d

echo "== waiting for health"
for i in $(seq 1 30); do
  unhealthy=$(docker ps --filter name=redis --format '{{.Names}} {{.Status}}' | grep -cv '(healthy)' || true)
  [ "$unhealthy" -eq 0 ] && break
  sleep 2
done
docker ps --filter name=redis --format '  {{.Names}} {{.Status}}'

echo "== verification"
fail=0
for r in "${AUTHED[@]}"; do
  anon=$(docker exec "$r" redis-cli PING 2>&1 || true)
  case "$anon" in *NOAUTH*) echo "  $r anonymous: refused (good)";; *) echo "  $r anonymous: '$anon' — EXPECTED NOAUTH"; fail=1;; esac
  authed=$(docker exec "$r" sh -c 'redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning PING')
  [ "$authed" = "PONG" ] && echo "  $r authed: PONG" || { echo "  $r authed: '$authed' — EXPECTED PONG"; fail=1; }
  post=$(docker exec "$r" sh -c 'redis-cli -a "$(awk "/^requirepass/{print \$2}" /usr/local/etc/redis/auth.conf)" --no-auth-warning DBSIZE')
  [ "$post" = "${PRE[$r]}" ] && echo "  $r keys: $post (unchanged)" || { echo "  $r keys: $post vs pre ${PRE[$r]} — MISMATCH"; fail=1; }
done

[ "$fail" -eq 0 ] && echo "== ALL CHECKS PASSED — watch the next cron burst" || { echo "== FAILURES ABOVE — see README rollback"; exit 1; }
