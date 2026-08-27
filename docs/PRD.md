# GridZero: Product Requirements Document

Version: 1.1 · Status: Active · Owner: Project Team — updated 2026-08-28

---

## 1. Vision

Disasters destroy cell towers before they destroy people. GridZero lets a disaster-relief camp run entirely without internet or cellular coverage: citizens broadcast SOS beacons, officers verify identities and distribute rations against a tamper-evident ledger, and a Command HQ laptop sees the whole camp on one map: all over phone-to-phone Bluetooth Low Energy mesh, with a local Wi-Fi bubble for bulk data when needed.

**One line:** an air-gapped, offline-first relief-camp operating system that fits in responders' pockets — now with HQ-signed trust, mesh chat, and verified landmarks on every map.

## 2. Problem

- After floods/earthquakes/cyclones, connectivity dies but aid must flow.
- Paper ration lists get lost, duplicated, forged; double-draws go undetected.
- SOS calls have no channel; triage is shouting and guesswork.
- HQ has no live picture of who needs help, where, or how badly.
- Open mesh without signatures invites fake accounts and spam bots.

## 3. Users & Roles

| Role | Device | Core jobs |
|---|---|---|
| **Citizen** | Android phone | Fire SOS; show rotating identity/ration QR; view own card + field map with verified landmarks; mesh chat (signed) |
| **Officer** | Android phone | Scan QR to issue claims; flag/revoke; respond to SOS; post signed landmarks (long-press map); sync ledger to HQ; mesh chat |
| **Admin / Command HQ** | Linux laptop (primary) + Windows HQ (full mesh via WinRT publisher patch) | Provision all accounts via HQ-signed QR (cert chain); host `GZ-<USER>` Wi-Fi link via `ap0` (`hostapd`/`dnsmasq`); view dashboard: live mesh map with landmarks, triage heatmap, audit log, officer registry, chat |

Accounts are never self-created: every identity is issued by HQ through HQ-signed provisioning QR codes (physical trust handoff, `GZCERT` + `GZPROV` sig). Fake QRs without the HQ authority are rejected once a HQ has been seen.

## 4. Feature Requirements

### FR-1: Offline Mesh Networking
- Phones + HQ form a BLE advertisement mesh; messages flood peer-to-peer (TTL 5, dedup 500-frame window, CRC8).
- Frame types: `SOS` (0x01), `heartbeat/announce` (0x02), `ledger-sync-req` (0x03), `identity` (0x04), `ledger-record` (0x05), `revocation` (0x06), `chat` (0x07, signed), `landmark` (0x08, HQ-certified ECDSA), `respond-ack` (0x09).
- Duty-cycle governor: `NOMINAL` 3s scan / 9s sleep (25%), `BURST` 3s/400ms after new peer or chat/announce (12s lease), `ALERT` continuous when SOS live. Linux HQ is `CONTINUOUS`.
- Reliability: multi-chunk payloads (`11B` slices, `GZCHAT` 3× repeat, single-chunk chat sticky 12s persistent so a 9s sleeper still catches it; BlueZ `InProgress` guard).

### FR-2: SOS & Triage
- Citizen raises SOS: severity 1–5 + needs bitfield (medical/trapped/water/food).
- Beacon propagates <15s across 3 hops; peers see radar/map with bearing/distance.
- Officer taps "respond"; 3× `respond` flood → citizen phone rings (speaker-forced) + banner `HELP ON THE WAY`.
- SOS auto-expires (90s lease) or explicit clear.

### FR-3: Ration Distribution
- Citizen shows QR that rotates every 30 s (HMAC-SHA256 TOTP, 30s window, ±1 tolerance) so screenshots die in ≤90 s.
- Officer scans → verifies TOTP + PIN-hash fallback + face embedding (on-device) → claim appended to hash-chain ledger, officer-signed (ECDSA P-256, deterministic).
- Daily duplicate guard; family cards fractional draws (0.25–1.0) against daily cap.
- Revoked/suspended cards refused; revocations flood via `0x06`.

### FR-4: Tamper-Evident Ledger
- Every claim `sha256(prevHash|record)` chained; `ECDSA P-256` per officer gives non-repudiation.
- Merge is additive, never rewrites local chain; conflicts rejected.

### FR-5: Provisioning & Identity — HQ-Signed Trust
- HQ issues accounts/family/officer promotions as **HQ-signed** multi-page QR envelopes (`GZ1|idx/total|crc` + `v2` envelope `{v,t,exp,nonce,data,sig}` where `sig = sign(authorityPriv, GZPROV|v|t|exp|nonce|canonicalData)` and `data` carries `cert = sign(authorityPriv, GZCERT|id|pubB64)`). `exp` 24h for accounts, 30d for family, 10m for hotspot.
- `ak` (authority pub) + `cert` travel in QR; first QR pins the HQ root on the phone; subsequent QRs must have `sig` verifiable against that root or are rejected as `fake account blocked`.
- `24h` is QR validity only — once provisioned the account (`hash` in `SharedPreferences`) never expires; the citizen logs in locally forever with username/password. Future internet login can reuse the same `hash`-derived key without a new QR.
- Face enrollment (MobileFaceNet 112×112) is on-device only, synced only via explicit Wi-Fi exchange.

### FR-6: Command HQ Dashboard + Maps
- Live `MeshMap` (same widget on HQ `dashboard_screen.dart:285`, citizen `map_screen.dart:35`, officer `officer_screen.dart:640`) shows every verified `officialLandmarks` as shield pins above chat; landmarks are HQ-certified (`GZCERT` + `GZANN1` sig) and auto-expire, so only real officers' marks appear — citizens and hacked apps cannot forge.
- Dashboard: live mesh map, triage heatmap, node list, audit log with sig badges; user/officer directories (search, re-issue QR, demote, delete); revocation panel; chat `MESH` tab.

### FR-7: Bulk Sync — HQ-Hosted Link
- HQ hosts `GZ-<USER>` WPA2 (`ap0` via `iw`/`hostapd`/`dnsmasq`/`nft` on `192.168.51.1/24`, `sudo -n` once; Windows HQ uses `netsh` client join plus `BluetoothLEAdvertisementPublisher` patch). Phone joins in-app (`WifiNetworkSuggestion`) and does a **two-way** `GZSYNC1|hash|len` TCP exchange on `:7941` — phone pushes its ledger/face, HQ pushes its snapshot and `reverse push` carries citizen embeddings back.
- No internet, no pairing, no manual Wi-Fi password typing (standard `WIFI:` QR on HQ).

### FR-8: Mesh Chat (Signed, English-efficient)
- 220B wire limit = 220 ASCII chars (1B UTF-8); Hindi/emoji 2–4B → ~70/55 chars. Pure ASCII 221–249 chars auto-packs 7-bit (`8→7B`) via `chat_codec.dart` so 249 English chars still fit 220B.
- Every chat is HQ-certified: `[wireLen][wire][uLen][username][pub65][cert64][sig64]` where `sig = sign(priv, GZCHAT|username|base64(wire))` and `wire = 0x00+utf8` or `0x01+7bit`. Receiver verifies `GZCERT` then `GZCHAT`; unverified/unsigned is shown as `UNVERIFIED` or dropped when a HQ has been pinned — bots cannot spam as a trusted officer.

## 5. Non-Goals (v1)

- Internet/cloud, remote HQ, multi-camp federation.
- iOS parity (Android + Linux HQ primary, Windows HQ full via patch).
- E2E encryption of mesh payloads (signing lands first; encryption roadmap).

## 6. Success Metrics

| Metric | Target |
|---|---|
| SOS 3-hop | < 15 s |
| Ration scan-to-ledger | < 10 s |
| Chat single-chunk catch by 9s sleeper | < 12 s (sticky) |
| Battery (citizen idle) | < 8%/day |
| Ledger duplicate rejection | 100% |
| Fake QR blocked after HQ seen | 100% |
| 200 devices stable | 24 h |

## 7. Constraints

- Zero infra; commodity Android + any Linux laptop with BT + sudo; Windows HQ via `TOOL` patches.
- All crypto local; no cloud.
- Patches under `tool/patches/` reapplied after every `pub get` (see `PATCHES.md`).

## 8. Risks (updated)

- 31B adv ceiling → 22B frame; rich data stays in QR/Wi-Fi, not mesh.
- mesh now **signed** (`GZCERT`/`GZCHAT`/`GZANN1`) — spoofing requires HQ `authorityPriv`.
- 16-bit `nodeId` collisions beyond few hundred nodes (dedup window bounds damage).

---

## Layman Terms

Flood knocks out towers. Phones become walkie-talkies over Bluetooth, hopping like a bucket brigade. SOS carries how bad and what is needed; officers tap "coming" and your phone rings. Food QR changes every 30s like a bank token — photos die quickly. Every transaction is glued to the previous one and signed, so nobody can secretly edit the receipt book. HQ laptop sees the whole camp on a map with verified officer pins. New IDs are only created by HQ as signed scannable codes; fakes are rejected automatically.
