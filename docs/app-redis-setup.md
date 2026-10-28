# Connecting Your App to Redis

For apps running on acq-vm-2. Written 2026-10-15. The Postgres equivalent is
`pg_manage_v2/docs/guides/app-db-login.md`.

## How Redis is set up here

There are four Redis instances, and **all four share one password**. Unlike
Postgres, there are no per-app logins yet, so you don't create a user. You copy
the shared password into your app's `.env`.

| Instance | Address on `redis_net` | Used by |
| --- | --- | --- |
| `redis_dev-0-4` | `redis_dev-0-4:6379` (`198.18.1.4`) | data_acquisition, hhm_rpp_ge, hhm_rpp_philips, hhm_rpp_siemens |
| `redis-STAGING` | `redis-STAGING:6379` (`198.18.1.3`) | nothing currently (holds a copy of the seed) |
| `redis-PROD` | `redis-PROD:6379` (`198.18.1.2`) | nothing currently (holds a copy of the seed) |
| `redis_dev-0-5` | `redis_dev-0-5:6379` (`198.18.1.5`) | spare |

Three things follow from this design:

- **Inside the server only.** Port 6379 isn't published and there's no TLS.
  Only containers attached to the Docker network `redis-admin_redis_net` can
  connect. An app hosted elsewhere (Azure App Service, your laptop) cannot use
  these instances.
- **The password opens everything.** With it you can read, change or wipe any
  key on any instance, including other apps' live state. Be careful with
  commands that touch more than your own keys.
- **Use a key prefix.** Instances are shared, so start every key with your
  app's name, such as `fleet-portal:session:123`. That's how you avoid
  overwriting another app's data.

## Step 1: Pick an instance

Ask the server owner which instance your app should use. `redis_dev-0-5` is the
spare and the usual choice for a new app. Don't point a new app at
`redis_dev-0-4` or `redis-STAGING` without agreement, because live jobs depend
on them.

## Step 2: Put the settings in your `.env`

Every app on this server keeps its Redis settings in three `.env` keys:

| Key | Value | Why |
| --- | --- | --- |
| `REDIS_HOST` | the instance name, e.g. `redis_dev-0-5` | Docker resolves container names on `redis_net`, so use the name, not the IP |
| `REDIS_PORT` | `6379` | Same for all four |
| `REDIS_PW` | the shared password (filled in below) | Read from a root-only file; never typed by hand |

Add the first two by hand, plus an empty `REDIS_PW=` line, to your app's `.env`
(your dev clone, e.g. `~/apps/fleet-portal/.env`). Also make sure `.env` is in
your `.gitignore`.

Then fill in the password without ever displaying it. Run on acq-vm-2, from
your app's folder:

```bash
PW="$(sudo awk '/^requirepass/{print $2}' /opt/resources/secrets/redis_auth.conf)"
sed -i "s|^REDIS_PW=.*|REDIS_PW=$PW|" .env
unset PW
chmod 600 .env
```

- `sudo awk ...` reads the password from the secret file that all four
  instances load. Only root can read that file, which is why `sudo` is needed.
- `sed -i` replaces the empty `REDIS_PW=` line with the real value. The value
  goes into the file and never onto your screen.
- `unset PW` clears it from your shell, and `chmod 600` makes `.env` readable
  only by you.

Check that it worked without printing the password. This counts filled-in
`REDIS_PW` lines and should print `1`:

```bash
grep -c '^REDIS_PW=.' .env
```

If your app also has a release copy in `/opt/apps/<app>`, its `.env` comes
from `build-release.sh`. Don't edit the release copy by hand.

## Step 3: Attach your container to `redis_net`

In your app's `docker-compose.yaml`, attach the service to the network and
declare that network as external, because the redis-admin project owns it:

```yaml
services:
  app:
    # ...
    environment:
      REDIS_HOST: ${REDIS_HOST}
      REDIS_PORT: "${REDIS_PORT}"
      REDIS_PW: ${REDIS_PW}
    networks:
      - redis_net
      - pg_net        # if the app also uses Postgres

networks:
  redis_net:
    external: true
    name: redis-admin_redis_net
  pg_net:
    external: true
```

`external: true` tells Compose to join an existing network rather than create
its own. Without it, your app gets a private network and can't see Redis.

## Step 4: Register your `.env` for password changes

When the shared password is rotated, `scripts/activate_redis_auth.sh` in this
repo rewrites `REDIS_PW` in every `.env` on its `ENVS` list. If your app isn't
on the list, it breaks with `WRONGPASS` after the next rotation.

Ask the server owner to add your paths, or add them yourself on the `DEV`
branch of redis-admin and release. Both copies go on the list:

```bash
  /opt/apps/fleet-portal/.env   /home/<you>/apps/fleet-portal/.env
```

## Step 5: Test the connection

Run on acq-vm-2. This starts a throwaway `redis-cli` container on the same
network your app will use:

```bash
REDISCLI_AUTH="$(sudo awk '/^requirepass/{print $2}' /opt/resources/secrets/redis_auth.conf)" \
  docker run --rm -e REDISCLI_AUTH --network redis-admin_redis_net redis:7-alpine \
  redis-cli -h redis_dev-0-5 PING
```

`REDISCLI_AUTH` is the environment variable `redis-cli` reads its password
from. Passing it this way keeps the password out of the command line and your
screen. Expect `PONG`. If you get `NOAUTH` or `WRONGPASS`, see Troubleshooting
below.

## Step 6: Connect from Node.js

The apps on this server use [node-redis](https://github.com/redis/node-redis)
v4 (`npm install redis@4`). Use one shared client:

```javascript
// redis.js
const { createClient } = require('redis');

const client = createClient({
  socket: {
    host: process.env.REDIS_HOST,
    port: Number(process.env.REDIS_PORT || 6379),
    connectTimeout: 5000,
    // node-redis retries forever by default, so an outage would hang the app; give up after 2 retries
    reconnectStrategy: (retries) =>
      retries >= 2 ? new Error(`Redis unreachable at ${process.env.REDIS_HOST}`) : Math.min((retries + 1) * 200, 1000),
  },
  password: process.env.REDIS_PW,
});

client.on('error', (err) => console.error('redis error:', err.message));

module.exports = client;
```

Then connect once at startup and prefix your keys:

```javascript
const redis = require('./redis');

await redis.connect();
await redis.set('fleet-portal:hello', 'world', { EX: 60 });   // expires in 60 s
console.log(await redis.get('fleet-portal:hello'));          // "world"
```

`EX` sets an expiry time. Use it for anything temporary (caches, sessions),
so keys don't pile up on a shared instance.

## Troubleshooting

| What you see | Cause | Fix |
| --- | --- | --- |
| `NOAUTH Authentication required` | The client sent no password | `REDIS_PW` is empty or isn't passed into the container (Steps 2 and 3) |
| `WRONGPASS invalid username-password pair` | Wrong or outdated password | Re-run Step 2. If it happened after a rotation, also do Step 4 |
| `getaddrinfo ENOTFOUND redis_dev-0-5` | Container isn't on `redis_net` | Add the network to your compose file (Step 3) and recreate the container |
| `Connection timeout` / `ECONNREFUSED` | Wrong host or port, or the instance is down | Check `REDIS_HOST`; run `docker ps --filter name=redis` to see each instance's health |
| The app hangs at startup | node-redis retrying forever | Add `connectTimeout` and `reconnectStrategy` (Step 6) |

## Coming later: per-app Redis users

Redis supports separate users (ACLs), each limited to its own key prefix. That
would give every app its own password, like Postgres. It needs changes to all
four instances' configs and is planned separately. This guide will be updated
when it lands.
