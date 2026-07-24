# BitQube Pool — Replication / Setup Guide

This is an **EasyNOMP** fork configured for **BitQube (BTQ), KawPoW**. It ships a
**vendored, patched `kawpow-stratum-pool`** (in `./stratum-pool`) because the
upstream `RavenCommunity/kawpow-stratum-pool` has two bugs that break a fresh
BitQube chain. Do **not** replace it with the upstream git dependency.

## Requirements

- **Node.js 12.x** (use `nvm install 12 && nvm use 12`). Newer Node breaks the
  vendored stratum-pool's native deps (`bignum`) and older winston/colorspace.
- **Redis** (`sudo apt install redis-server`).
- A synced **bitqubed** with RPC enabled (`server=1`, `rpcuser`, `rpcpassword`,
  `rpcallowip=127.0.0.1`, `rpcport=8766`).

## Install

```bash
nvm use 12
npm ci      # deterministic install from the committed package-lock.json (preferred)
```

Prefer `npm ci`. If you run `npm install` instead, npm re-nests a newer
`@dabh/diagnostics` whose `@so-ric/colorspace` uses `||=` (Node 15+ syntax) and
`node init.js` crashes with `SyntaxError: Unexpected token '='`. The committed
`package-lock.json` + the `resolutions` block pin it to `@dabh/diagnostics@2.0.3`.
To repair a bad `npm install` tree:

```bash
npm install --no-save npm-force-resolutions
./node_modules/.bin/npm-force-resolutions   # rewrites package-lock.json per "resolutions"
rm -rf node_modules && npm install
```

Then configure and run:

```bash
cp config_example.json config.json          # edit stratumHost, etc.
cp pool_configs/bitqube_example.json pool_configs/bitqube.json
node init.js
```

**pool_configs/bitqube.json** — set your RPC user/password in **BOTH** places:
`paymentProcessing.daemon` **and** the top-level `daemons` array. The stratum
worker uses `daemons`; the payment processor uses `paymentProcessing.daemon`. If
only one is set you get `Unauthorized RPC access` from `[Pool]` while the payment
processor still works (or vice-versa). Then **remove `bitqube_example.json`** from
`pool_configs/` — NOMP loads **every** `*.json` there, and the example's
placeholder creds (`"enabled": true`) otherwise cause "Unauthorized RPC access".

The `coin` field is used **verbatim** as the filename, so it must be
`"coin": "bitqube.json"` (with the extension) to match `coins/bitqube.json`.

## The two patches in ./stratum-pool (already applied)

If you ever re-vendor from upstream, you MUST re-apply these:

1. **`lib/jobManager.js` — `JobCounter.cur`.** Upstream uses invalid
   `Buffer.writeUIntBE(counter, 24, 8)` (byteLength max is 6) → crashes every
   stratum worker on the first job. Fixed to:
   ```js
   var counter_buf = Buffer.alloc(32);
   counter_buf.writeUIntBE(counter, 26, 6);
   return counter_buf.toString('hex');
   ```

2. **`lib/transactions.js` — coinbase BIP34 block height.** Upstream hand-builds
   the height as a length-prefixed push (`01 0b` for height 11), which consensus
   rejects with **`bad-cb-height`** for heights 1–16 (it expects `OP_N`, e.g.
   `OP_11` = `0x5b`). Only bites the first 16 blocks of a new chain. Fixed by
   routing the height through `util.serializeNumber(blockHeight)` (which emits
   `OP_N` for 1–16 and length-prefixed pushes otherwise, matching Bitcoin Core's
   `CScript() << nHeight`).

## Difficulty for small GPUs

Port **10032** carries an explicit low starting `"diff": 0.05` (`minDiff: 0.02`).
Without a starting `diff`, NOMP hands new miners a high default (~8), which is ~50
min/share on an ~11 MH/s card, and vardiff can't lower it (it only retargets on
share submission) → a deadlock of zero shares. t-rex shows share diff in ethash
units = `poolDiff × 2^32` (so `0.05` displays as `~215 M`).

## Miner command (KawPoW GPU)

```bash
t-rex -a kawpow -o stratum+tcp://YOUR_SERVER_PUBLIC_IP:10032 -u <BTQ_address> -w rig1 -p x
```
Stratum ports are raw TCP — point miners at the server IP / a DNS-only host, not
a Cloudflare-proxied name. nginx (`pool.bitqube.org.conf`) only proxies the
website (`:8080`), never stratum.

## Running on a small / memory-constrained box

On a ~2 GB VPS the **Website/Stats worker** can OOM as the chain grows: the global
Redis zset `statHistory` accumulates one full stats snapshot per `updateInterval`,
and each snapshot serializes every confirmed block, so it balloons to hundreds of
MB. `stats.js` parses the whole thing to render the home page → `node` OOMs → the
Website worker dies (home page returns **504**), and with no swap the OS may also
kill Redis (`ECONNREFUSED`). Mining and payouts are unaffected — they run in
separate workers backed by Redis, so payout data is never lost.

Mitigations (in order of impact):

1. **Add swap** (a ~2 GB swapfile) so spikes don't OOM-kill Redis:
   `sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab`
2. Keep `website.stats.historicalRetention` low (default here is **1800**, ~360
   snapshots at `updateInterval:5`). Do NOT raise Node's `--max-old-space-size`
   on a small box — that makes the OOM-kill worse.
3. If `statHistory` has already bloated, trim it (safe — it is only graph history,
   not blocks/balances/payments):
   `redis-cli ZREMRANGEBYRANK statHistory 0 -361`  (keeps the newest 360)
   Verify with `redis-cli info memory | grep used_memory_human`.
