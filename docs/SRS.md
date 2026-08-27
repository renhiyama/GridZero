# GridZero: Software Requirements Specification

Version: 1.1 · Status: Active · Conformance: IEEE-830-inspired, condensed
Companion to `PRD.md`. Wire-format in `BLE_MESH_STACK.md`.

---

## 1. Scope

GridZero is a Flutter application (Android client, Linux HQ primary + Windows HQ via WinRT patch) providing offline disaster-relief coordination: BLE advertisement mesh messaging (now HQ-signed), SOS triage, ration distribution against a tamper-evident ledger, and HQ provisioning/sync. Future internet login can reuse the same hash-derived keys without a new QR.

## 2. System Context

```
[Citizen phone] ~BLE~ [Officer phone] ~BLE~ [Citizen phone]
        \                |                /
         ~BLE flood mesh (TTL 5, signed chat/landmark)~
                         |
              [HQ Linux/Windows laptop] --Wi-Fi link (TCP :7941, GZSYNC1)-- any phone
              HQ hosts GZ-<USER> WPA2 ap0 (192.168.51.1/24) or joins phone hotspot on Windows
```

Platforms: Android 12+ (primary), Linux x64 desktop (HQ), Windows x64 (HQ via `tool/patches/windows_ble_advertise`), iOS present but unsupported in v1.

## 3. Functional Requirements

### 3.1 Identity & Accounts
- FR-3.1.1 Roles: `citizen`, `officer`, `admin` (`lib/core/app_state.dart:39`).
- FR-3.1.2 Accounts per-device `SharedPreferences` JSON; no cross-device login. Hash is `sha256(password)` (64 hex).
- FR-3.1.3 Admin passwordless with `adminTerminal` flag persisting across wipe.
- FR-3.1.4 Officers only via promotion from existing user; demotion preserves ledger.

### 3.2 Provisioning — HQ-Signed Trust
- FR-3.2.1 Paged QR `GZ1|i/n|crc32|slice`, order-independent, full CRC32 (`lib/core/provision_packet.dart`).
- FR-3.2.2 Typed v2 envelope `{v:2,t,exp,nonce,data,sig?}` where `sig = sign(authorityPriv, GZPROV|v|t|exp|nonce|canonicalData)` and `canonicalData` is sorted-key JSON of `data`. `exp`: account 24h, family 30d, hotspot 10m. `sig` covers `data` including `cert`.
- FR-3.2.3 Account data carries `p,u,h,pin,a,f,oid,ak,cert` where `cert = sign(authorityPriv, GZCERT|id|pubB64)` and `pub` is `deriveSigningKey(hash)` (`lib/core/ledger/officer_sign.dart:105`). `ak` is authority pub. First QR pins `ak` as trust root; subsequent QRs must have valid `sig` against that root or are rejected as fake.
- FR-3.2.4 `24h` is QR validity only — once `provisionAccount` saves the hash, the account never expires; local `login` is offline forever. Future internet login can reuse same hash-derived key.
- FR-3.2.5 HQ persists `cert_sig_$id` for every issued account at `accountProvisionPayload` time.

### 3.3 Mesh Networking
- FR-3.3.1 Fixed 22-byte frame, magic `0xA5`, types: `0x01 SOS`, `0x02 heartbeat`, `0x03 ledger-sync-req`, `0x04 identity`, `0x05 ledger-record`, `0x06 revocation`, `0x07 chat` (signed), `0x08 landmark` (HQ-certified), `0x09 respond-ack` (`lib/core/mesh_packet.dart`).
- FR-3.3.2 Flooding TTL 5, hop+1.
- FR-3.3.3 Dedup `(senderId<<16)|seq` LRU 500 (`lib/core/nonce_dedup.dart`).
- FR-3.3.4 CRC8 poly 0x07 over 0–15.
- FR-3.3.5 Governor tiers `ALERT` (SOS) continuous, `BURST` 3s/400ms 12s lease on new peer *or* any `chat`/`announce`, `NOMINAL` 3s/9s, `STANDBY` 3s/27s (`lib/core/mesh/native_mesh.dart:56`).
- FR-3.3.6 Single slot queue max 32, sticky persistent; `chat` single-chunk is sticky 12s + 2 quick re-airs so a 9s sleeper catches it; multi-chunk 3× repeat with 500ms pacing and dedupKey reuse (`lib/core/mesh/mesh_controller.dart:437`).
- FR-3.3.7 Windows HQ `BluetoothLEAdvertisementPublisher` patch (`tool/patches/windows_ble_advertise*`) gives full TX/RX on `WinMeshAdapter`.

### 3.4 Location
- FR-3.4.1 Movement-gated GPS (25-sample variance, rising edge, 10s refetch floor, 2-min stale watchdog).
- FR-3.4.2 No-GPS consensus median of peers, outlier >3× median rejected.

### 3.5 SOS & Response
- FR-3.5.1 SOS `severity 1–5` + `TriageFlags` bitfield.
- FR-3.5.2 SOS wins persistent slot every 10s heartbeat.
- FR-3.5.3 Peer SOS lease 90s; sweep drops silent >2min.
- FR-3.5.4 `respond-ack` 3× flood → target rings via `AudioAlert` speakerphone.
- FR-3.5.5 Banner + notification deep-link.

### 3.6 Ration Claims & Ledger
- FR-3.6.1 Citizen QR `{v,c,w,tok,n,ph,f}`; `tok` = HMAC-SHA256 16 hex, `window 30s ±1`.
- FR-3.6.2 Officer verify: TOTP → PIN-hash fallback + face → revocation → family cap → append.
- FR-3.6.3 Ledger `recordId = sha256(citizen|ration|ts)[0:24]`; `hash = sha256(prevHash|record)`; genesis `GridZero-Genesis-Anchored`.
- FR-3.6.4 Append requires `prevHash==tail`; unique `(citizen, ration, day)`.
- FR-3.6.5 ECDSA P-256 deterministic, 64B `r||s` + 65B pub, local only.
- FR-3.6.6 Revocations `0x06` mesh-diffused.
- FR-3.6.7 Merge into `sync_records`, preserve hashes, reject cross-officer double-claim.

### 3.7 Face Enrollment
- FR-3.7.1 MobileFaceNet 112², MLKit detect → eye-center → L2 blob per citizen.
- FR-3.7.2 Offered once post-provision; re-enrollable; synced only via Wi-Fi exchange.

### 3.8 Bulk Sync — HQ-Hosted Link
- FR-3.8.1 `GZSYNC1|sha256|len` TCP `:7941`, two-way in one connection; sha256 verified both ways.
- FR-3.8.2 HQ hosts `ap0` (`hostapd`/`dnsmasq` `192.168.51.1/24`, `nft` masquerade) or on Windows joins phone hotspot via `netsh`; phone `WifiNetworkSuggestion` + `gridzero/link` channel, purged after.
- FR-3.8.3 Snapshot `records+revocations+officers+family+face`; import merges without rewrite.

### 3.9 Chat — Signed & English-Efficient
- FR-3.9.1 Wire limit 220B = 220 ASCII (1B UTF-8); Hindi/emoji 2–4B → ~70/55 chars. Pure ASCII 221–249 auto-packs 7-bit `8→7` via `lib/core/chat_codec.dart` (`GZCHAT`).
- FR-3.9.2 Every chat is `wireLen|wire|uLen|username|pub65|cert64|sig64` where `sig=sign(priv, GZCHAT|username|base64(wire))` and `cert=GZCERT|id|pub`. Receiver verifies `GZCERT` against `authorityPub`, then `GZCHAT`; unverified is dropped when HQ has been pinned. Own message added immediately; cooldown 15s.

### 3.10 Landmarks — Verified on Every Map
- FR-3.10.1 Officer long-press map → `postOfficialLandmark` builds `GZANN1|lat|lon|type|expiry|label` (7-decimal) signed with `deriveSigningKey(hash)` and `cert = GZCERT|officerId|pub`; blob `[lat4 lon4 type1 expiry4 labelLen label idLen id pub65 cert64 sig64]` chunked via `0x08`. Verifier `lib/core/app_state.dart:1941` checks `GZCERT` then `GZANN1` before `ledger.upsertLandmark` and `officialLandmarks`.
- FR-3.10.2 `MeshMap` on HQ `dashboard_screen.dart:285`, citizen `map_screen.dart:35`, officer `officer_screen.dart:640` all render `officialLandmarks.where(!expired)` as shield pins; citizen sees same verified pins, hacked apps cannot forge.

### 3.11 UI Shell
- FR-3.11.1 Admin: HQ/Users/Officers/Sync/Register/Settings; Citizen(+Officer): Citizen/Map/[Officer]/Settings (`shell.dart`).

## 4. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-1 Performance | SOS 3-hop <15s; heartbeat 10s; chat single-chunk <12s (sticky) |
| NFR-2 Battery | Governor 25% NOMINAL, 10% STANDBY; Linux CONTINUOUS |
| NFR-3 Reliability | CRC8, LRU-500, 3× chat repeat, 12s sticky, BlueZ InProgress guard |
| NFR-4 Integrity | Hash chain, duplicate guard, `GZPROV`/`GZCERT`/`GZCHAT`/`GZANN1` ECDSA, CRC32 provisioning, sha256 sync |
| NFR-5 Auditability | `[SIG✓]` badges; HQ directory shows `GZCERT` status |
| NFR-6 Portability | Linux+Windows HQ, Android phones; graceful degrade (no GPS/camera) |
| NFR-7 Privacy | Face local until explicit sync; directories show roles, never hashes |

## 5. Security Model (v1.1)

- Implemented: hash chain, RFC6979 ECDSA, TOTP/PIN, LRU dedup, CRC8/32, sha256 sync, **HQ-signed provision (`GZPROV` + `GZCERT`) blocks fake accounts, signed `GZCHAT` blocks bot spam, `GZANN1` landmark chain blocks fake pins** — all verified against pinned `authorityPub` (`kAuthorityPubPref`).
- Remaining gaps: ledger `CompactRecord` and `SOS` beacons are still plaintext + unsigned (next: `GZSOS`/`GZLEDGER` signed blobs via same `GZCERT` pattern); DB sync has hash integrity but no TLS (air-gapped Wi-Fi anyway); ADMIN passwordless is physical-possession trust; officer priv stored plaintext in Memory/SQlite via `deriveSigningKey` (deterministic from hash, not random).

## 6. Data Dictionary

| Entity | Fields |
|---|---|
| Account | username, role, hash(64 hex), pinHash?, aadhaar?, familyId?, officerId?, certB64 (pinned) |
| ProvisionEnvelope | v, t, exp, nonce, data{...cert,ak}, sig? (GZPROV) |
| LedgerRecord | recordId, citizenId, rationCode, claimedAt, officerId, prevHash, currentHash, sig?, pub? |
| ChatWire | flag 0x00+utf8 or 0x01+7bit packed, max 220B wire (251 packed English) |
| SignedChatBlob | wireLen2, wire, uLen, username, pub65, cert64, sig64 (GZCHAT) |
| Revocation | citizenTag, digestTag, action, origin, ts |
| MeshNode | id(u16), lat/lon, severity, rssi, hops, lastSeen, username, role |
| OfficialLandmark | label, typeCode, lat/lon, expiry, officerId, sig (GZANN1) |

## 7. Acceptance Criteria

- AC-1: 3 phones relay SOS 2 hops <15s.
- AC-2: Same citizen+ration double-claim same day by two officers → second rejected.
- AC-3: Tampering any ledger byte fails merge or breaks chain.
- AC-4: Screenshot QR after 90s fails TOTP.
- AC-5: HQ↔phone two-way exchange in one TCP; corrupt frame aborts.
- AC-6: Wiping HQ wipes ADMIN, repins HQ root on next QR.
- AC-7: QR without HQ `sig` after root pinned is rejected as `fake account blocked`.
- AC-8: Unsigned `GZCHAT` from unknown pub after root pinned is dropped; signed chat from real officer/citizen appears on all three maps.

---

## Layman Terms

Three people: residents, aid workers, head office. No one self-registers — HQ prints a signed scannable code that is the only way to get an account (like a signed wristband). Phones shout over Bluetooth; each shout has a hop counter and fingerprint so garbled or duplicate shouts die quickly. Help cries say how bad and what is needed; responders' answer makes the phone ring. Food barcodes tick every 30s; the receipt book is glued page-to-page and each page is signed. Now every chat and every map pin is also signed with the same wristband key and double-checked against HQ's master stamp — fakes from a hacked app are thrown away, and only real officers' pins show on everyone's map.
