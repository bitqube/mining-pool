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
npm install                 # installs deps + links ./stratum-pool via "file:"
cp config_example.json config.json                 # then edit stratumHost, etc.
cp pool_configs/bitqube_example.json pool_configs/bitqube.json
#   ^ edit RPC user/password to match bitqube.conf; remove the *_example.json
#     from pool_configs/ so NOMP does not load its placeholder credentials.
node init.js
```

`pool_configs/` note: NOMP loads **every** `*.json` in that folder. Keep only your
real `bitqube.json` (+ any disabled coins). A leftover `*_example.json` with
`"enabled": true` and placeholder creds causes "Unauthorized RPC access".

The `coin` field in a pool config is used **verbatim** as the filename, so it must
be `"coin": "bitqube.json"` (with the extension) to match `coins/bitqube.json`.

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
