# BitQube Mining Pool (BTQ · KawPoW)

The official mining pool for **BitQube (BTQ)** — an [EasyNOMP](https://github.com/EasyX-Community/EasyNOMP)
fork carrying a **vendored, patched `kawpow-stratum-pool`** (in `./stratum-pool`).

> **Do not** replace the vendored stratum-pool with the upstream
> `RavenCommunity/kawpow-stratum-pool` git dependency. Upstream has two bugs that
> make a fresh BitQube chain unmineable — see
> [docs/BITQUBE-SETUP.md](docs/BITQUBE-SETUP.md#the-two-patches-in-stratum-pool-already-applied).

This README is the **runbook**: install → configure → run → maintain. For the
"why" behind each patch and workaround, read
[docs/BITQUBE-SETUP.md](docs/BITQUBE-SETUP.md).

---

## Contents

- [Requirements](#requirements)
- [1. Install the BitQube daemon](#1-install-the-bitqube-daemon)
- [2. Install the pool](#2-install-the-pool)
- [3. Configure the pool](#3-configure-the-pool)
- [4. Run the pool](#4-run-the-pool)
- [5. Point a miner at it](#5-point-a-miner-at-it)
- [6. Web front-end (nginx)](#6-web-front-end-nginx)
- [Maintenance runbook](#maintenance-runbook)
- [Troubleshooting](#troubleshooting)
- [Layout](#layout)

---

## Requirements

| Component | Version | Notes |
| --- | --- | --- |
| Ubuntu Server | 20.04 LTS | 22.04 works; anything with `redis-server` in apt |
| **Node.js** | **12.x (via nvm)** | **Hard requirement.** Newer Node breaks the vendored stratum-pool's native deps (`bignum`) and older winston |
| Redis | 5+ | `sudo apt install redis-server` |
| `bitqubed` | 1.0.0+ | Synced, RPC enabled |
| RAM | **4 GB + 2 GB swap minimum** | The stats worker is the memory hog — see [Maintenance](#maintenance-runbook) |

Ports used: stratum **10008 / 10032 / 10256** (raw TCP), website **127.0.0.1:8080**,
NOMP CLI **127.0.0.1:17117**, daemon RPC **127.0.0.1:8766**.

---

## 1. Install the BitQube daemon

```bash
adduser bitqubemaster
usermod -aG sudo bitqubemaster
su - bitqubemaster

wget https://github.com/bitqube/bitqube/releases/download/v1.0.0/bitqube-1.0.0-x86_64-linux-gnu.tar.gz
tar -xf bitqube-1.0.0-x86_64-linux-gnu.tar.gz
rm bitqube-*.tar.gz

mkdir -p ~/.bitqube
cat > ~/.bitqube/bitqube.conf <<'EOF'
server=1
daemon=1
rpcuser=CHANGE_ME
rpcpassword=CHANGE_ME_TO_SOMETHING_LONG
rpcallowip=127.0.0.1
rpcbind=127.0.0.1
rpcport=8766
EOF
chmod 600 ~/.bitqube/bitqube.conf

cd bitqube-1.0.0/bin
./bitqubed
```

The binaries are statically linked (glibc only) — no dependency install needed.

Create the pool's wallet address and note it down; it goes in
`pool_configs/bitqube.json` as `address` / `rewardRecipients`:

```bash
./bitqube-cli getnewaddress          # -> B... (the pool's payout/fee address)
./bitqube-cli getblockcount          # sync progress
./bitqube-cli getwalletinfo
```

> **Do not start the pool until the daemon is fully synced.** The pool builds
> block templates from `getblocktemplate`; on an unsynced node it will hand out
> stale work.

---

## 2. Install the pool

```bash
# Node 12 via nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 12 && nvm use 12

sudo apt update
sudo apt install -y git build-essential autoconf pkg-config make gcc g++ \
                    screen redis-server ntp

cd ~
git clone https://github.com/bitqube/mining-pool.git
cd mining-pool
npm ci            # deterministic install from the committed package-lock.json
```

**Use `npm ci`, not `npm install`.** `npm install` re-nests a newer
`@dabh/diagnostics` whose `@so-ric/colorspace` uses `||=` (Node 15+ syntax), and
`node init.js` then dies with `SyntaxError: Unexpected token '='`. The committed
`package-lock.json` plus the `resolutions` block pin it to `@dabh/diagnostics@2.0.3`.

If you already broke the tree with `npm install`, repair it:

```bash
npm install --no-save npm-force-resolutions
./node_modules/.bin/npm-force-resolutions
rm -rf node_modules && npm install
```

`install.sh` performs the apt + nvm + `npm ci` steps above in one shot.

---

## 3. Configure the pool

Two files. Both are gitignored (they hold real credentials) — copy them from the
committed `*_example` templates:

```bash
cp config_example.json config.json
cp pool_configs/bitqube_example.json pool_configs/bitqube.json
rm pool_configs/bitqube_example.json     # IMPORTANT — see below
```

### `config.json` — portal-wide

Set `website.stratumHost` to the server's **public IP or a DNS-only (grey-cloud)
hostname**. Stratum is raw TCP; it cannot go through a Cloudflare-proxied name.

Leave these as shipped unless you know why you're changing them:

| Key | Value | Why |
| --- | --- | --- |
| `website.host` / `port` | `127.0.0.1` / `8080` | nginx terminates TLS in front (step 6) |
| `website.stats.historicalRetention` | `1800` | Higher values bloat Redis — see [Maintenance](#maintenance-runbook) |
| `website.stats.updateInterval` | `5` | One `statHistory` snapshot every 5 s |
| `clustering.enabled` | `false` | One box, one pool process |

### `pool_configs/bitqube.json` — the pool itself

Three gotchas here, all of which will silently break the pool:

1. **`"coin": "bitqube.json"` — with the `.json` extension.** `init.js` uses the
   `coin` value *verbatim* as the filename (`coins/` + value); it does **not**
   append `.json`. `"bitqube"` fails with `could not find file coins/bitqube`.
2. **Set the RPC user/password in BOTH places** — `paymentProcessing.daemon`
   *and* the top-level `daemons[]` array. The stratum worker reads `daemons`; the
   payment processor reads `paymentProcessing.daemon`. Setting only one gives
   `Unauthorized RPC access` from `[Pool]` while payments still work (or vice-versa).
3. **Delete `bitqube_example.json` from `pool_configs/`.** NOMP loads **every**
   `*.json` in that directory, so the example's placeholder credentials
   (`"enabled": true`) get loaded too and throw `Unauthorized RPC access`.

Stratum ports as shipped:

| Port | Starting diff | For |
| --- | --- | --- |
| `10008` | 2 | Mid-range GPUs |
| `10032` | **0.05** (minDiff 0.02) | Small GPUs / laptops — vardiff |
| `10256` | vardiff 1000–9000 | Rigs / farms |

Port 10032 **must** keep an explicit low starting `diff`. Without one, NOMP hands
new miners ~8, which is ~50 min/share on an ~11 MH/s card — and vardiff can't
lower it, because it only retargets *on share submission*. Zero shares, deadlock.
(t-rex displays share difficulty in ethash units = `poolDiff × 2^32`, so `0.05`
shows as `~215 M`.)

---

## 4. Run the pool

```bash
cd ~/mining-pool
./pool-start.sh          # starts under pm2 if available, else screen
./pool-status.sh         # instance count, redis memory, website health
./pool-logs-watch.sh     # tail logs  (optional arg = grep filter)
./pool-restart.sh
./pool-stop.sh
```

Or run it in the foreground while debugging:

```bash
nvm use 12 && node init.js
```

A healthy start prints, in order: `Master`, the stratum ports listening, the
website worker on `127.0.0.1:8080`, `PaymentProcessor` connected, and `CLI`.

> ### ⚠️ Run exactly ONE instance
> Two `init.js` processes against the same Redis double-append to the global
> `statHistory` zset and will exhaust the box's RAM within hours. `pool-start.sh`
> refuses to start if one is already running. Verify by hand any time something
> looks wrong:
> ```bash
> ps aux | grep '[i]nit.js' | wc -l      # must be 1
> ```

---

## 5. Point a miner at it

```bash
t-rex -a kawpow -o stratum+tcp://YOUR_SERVER_IP:10032 -u YOUR_BTQ_ADDRESS -w rig1 -p x
```

Use the server's IP or a DNS-only hostname — **never** a Cloudflare-proxied name.
Open the stratum ports in the firewall:

```bash
sudo ufw allow 10008,10032,10256/tcp
```

---

## 6. Web front-end (nginx)

The pool website listens on plain HTTP at `127.0.0.1:8080`; nginx terminates TLS
in front of it.

```bash
sudo cp pool.bitqube.org.conf /etc/nginx/sites-available/
sudo ln -sf /etc/nginx/sites-available/pool.bitqube.org.conf /etc/nginx/sites-enabled/
sudo certbot --nginx -d pool.bitqube.org
sudo nginx -t && sudo systemctl reload nginx
```

**The symlink into `sites-enabled/` is mandatory** — Debian/Ubuntu nginx only
auto-includes `sites-enabled`, and a missing symlink silently serves the default
"Welcome to nginx" page.

nginx proxies **only** the website. Stratum is never proxied. If the site sits
behind Cloudflare, keep the zone on **Flexible/Full** — switching to *Full
(strict)* has taken the main site down before.

---

## Maintenance runbook

### Daily / weekly health check

```bash
./pool-status.sh
```

Equivalent by hand:

```bash
ps aux | grep '[i]nit.js' | wc -l                      # must be exactly 1
free -m                                                 # available should not be near 0
redis-cli info memory | grep used_memory_human          # should stay well under 1G
redis-cli ZCARD statHistory                             # should sit near historicalRetention/updateInterval (~360)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/   # 200
./bitqube-cli getblockcount                             # daemon still syncing/current
```

### The one failure that keeps recurring: Redis bloat

**Symptoms:** home page shows `Cannot GET /` or nginx `504`; `free -m` shows the
box in swap; `redis-cli info memory` shows Redis at multiple GB.

**Cause.** The global `statHistory` zset accumulates one full stats snapshot per
`updateInterval`, and every snapshot serializes *all confirmed blocks* (~150 KB
once the chain has ~900 blocks). `stats.js` parses the entire zset to render the
home page, so the Website worker OOMs and dies. Two things drive it:

1. **Duplicate pool instances** — an old `node init.js` left running from a
   previous day alongside the current one, both appending to the same zset.
2. **`historicalRetention` left at the upstream default of 43200.**

**Recovery, in this order:**

```bash
# 1. stop EVERY pool instance (there may be more than one)
pkill -f init.js
sleep 1 && ps aux | grep '[i]nit.js' | wc -l          # -> 0

# 2. trim the history zset and hand memory back to the OS
redis-cli ZCARD statHistory
redis-cli ZREMRANGEBYRANK statHistory 0 -361          # keeps the newest 360
redis-cli MEMORY PURGE
redis-cli info memory | grep used_memory_human        # should drop under ~100M

# 3. confirm retention is 1800 in config.json, then start ONE pool
grep historicalRetention config.json
./pool-start.sh
```

Trimming `statHistory` is **safe** — it is graph history only. Blocks, balances,
shares and payments live in separate Redis keys and are untouched. `pool-reset-stats.sh`
wraps steps 1–3.

**Mining and payouts are unaffected by all of this.** They run in separate
Redis-backed workers, so blocks found and payouts owed survive a website OOM, a
Redis restart, and a full pool restart.

### Memory rules for a small box

- **Add swap** if there is none:
  ```bash
  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
  sudo mkswap /swapfile && sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  ```
- **Do NOT raise Node's `--max-old-space-size`** on a small box. It lets the
  worker grow until the OOM-killer takes Redis with it, which is strictly worse.
- Keep `historicalRetention` at `1800`.
- A VPS RAM upgrade needs a **full power-off → resize → power-on** at the
  provider panel. A soft `reboot` does not apply it — check `free -m` afterwards
  and don't assume the resize landed.

### Upgrading the pool

```bash
cd ~/mining-pool
./pool-stop.sh
git pull
npm ci                  # only if package.json / package-lock.json changed
./pool-start.sh
```

`config.json` and `pool_configs/bitqube.json` are gitignored, so a pull never
clobbers your credentials.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `SyntaxError: Unexpected token '='` on startup | `npm install` re-nested `@dabh/diagnostics` | `npm ci` (or the `npm-force-resolutions` repair above) |
| `could not find file coins/bitqube` | `coin` field missing the `.json` extension | `"coin": "bitqube.json"` |
| `Unauthorized RPC access` from `[Pool]` | RPC creds missing from top-level `daemons[]` | Set creds in **both** `daemons[]` and `paymentProcessing.daemon` |
| `Unauthorized RPC access` right after install | `bitqube_example.json` still in `pool_configs/` | Delete it — NOMP loads every `*.json` there |
| Blocks found but rejected `bad-cb-height` | Upstream stratum-pool coinbase height encoding | Use the vendored `./stratum-pool` (already patched) |
| Miner connects, 0 shares, huge diff (`34.49 G`) | No starting `diff` on port 10032 | `"diff": 0.05`, `minDiff: 0.02` |
| `Cannot GET /` or nginx 504 | Redis bloat / duplicate instances | [Recovery steps above](#the-one-failure-that-keeps-recurring-redis-bloat) |
| nginx serves "Welcome to nginx" | Missing `sites-enabled` symlink | `ln -sf` the conf into `sites-enabled/` |
| Native module build failure on `npm ci` | Wrong Node version | `nvm use 12` |
| `Could not retrieve account for B6Vh... from RPC` | BitQube dropped the legacy `account` RPC | Harmless warning; review payment code before relying on auto-payouts |

---

## Layout

```
init.js                     entry point — loads config.json + pool_configs/*.json
config.json                 portal config          (gitignored; from config_example.json)
pool_configs/bitqube.json   pool + RPC config      (gitignored; from bitqube_example.json)
coins/bitqube.json          coin profile: BTQ, kawpow, 60 s blocks, explorer URLs
stratum-pool/               VENDORED patched kawpow-stratum-pool — do not swap for upstream
website/                    front-end (BitQube themed)
libs/                       NOMP internals: stats.js, paymentProcessor.js, website.js …
docs/BITQUBE-SETUP.md       deep-dive: the patches, the gotchas, the reasoning
pool.bitqube.org.conf       nginx reverse-proxy for the website
pool-*.sh                   operational scripts (start/stop/restart/status/logs/reset-stats)
```

Upstream projects this builds on: [EasyNOMP](https://github.com/EasyX-Community/EasyNOMP),
[kawpow-stratum-pool](https://github.com/RavenCommunity/kawpow-stratum-pool),
[node-multi-hashing](https://github.com/EasyX-Community/node-multi-hashing). Licensed GPL-2.0.
