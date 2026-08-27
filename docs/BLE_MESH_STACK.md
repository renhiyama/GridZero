# GridZero: BLE Mesh Stack

Version: 1.1 · Status: Active · Pure prose (wire contract) — updated 2026-08-28
Companion to `SRS.md` §3.3.

---

## 1. Why an *advertisement* mesh

GridZero rides **BLE advertising packets** (one-shot manufacturer-data broadcasts, not GATT connections):
- **Connectionless:** hundreds of peers, no pairing.
- **Lossy:** unacked; reliability via `TTL` flood + `3×` repeat + sticky dwell.
- **Platform:** Android `flutter_blue_plus`/`ble_peripheral_plus` (patched), Linux `BlueZ` D-Bus, Windows `BluetoothLEAdvertisementPublisher` (patch `tool/patches/windows_ble_advertise`), all `0xFFFF`.

## 2. Radio capacity

Legacy adv `31B` → `1B len +1B type 0xFF +2B company 0xFFFF =4B` overhead → **27B** for GridZero, we use **22B**. Rich data (ledger, face, account blobs) travels via `GZ1|crc` QR pages or `GZSYNC1` Wi-Fi (`ap0` `192.168.51.1/24`).

## 3. Frame format (22B, big-endian)

| Byte(s) | Field | Notes |
|---|---|---|
| 0 | MAGIC `0xA5` | |
| 1 | TYPE | `0x01 SOS, 0x02 heartbeat, 0x03 ledger-req, 0x04 identity, 0x05 ledger-record, 0x06 revocation, 0x07 chat, 0x08 landmark, 0x09 respond` |
| 2–3 | SENDER_ID uint16 | |
| 4–7,8–11,12,17,18–21 | PAYLOAD | Overloaded per type (see below) |
| 13 | TTL_HOP | high nibble TTL 5, low nibble hops |
| 14–15 | SEQ uint16 | |
| 16 | CRC8 poly 0x07 over 0–15 | |
| 17 | FLAGS | SOS cleared bit; per-type length/marker |
| 18–21 | ALTITUDE int32 cm | `0x80000000` = unknown |

**Payload reuse for `0x07`/`0x08` (11B chunk):** `byte4=index, byte12=total, byte17=len(1..11), bytes5-7,8-11,18-21=slice` → `MeshDataChunk.chunkBytes=11`, `total` up to 40 (max `440B` payload, chat caps `220B` wire).

IDs `CIT-XXXXXXXX` pack 4B hex; else hashed.

## 4. Data payloads — signed where it matters

- **Chat `0x07`:** `wire = 0x00+utf8` or `0x01+7bit` (`chat_codec.dart` 8→7 pack → 249 English chars in 220B). Signed blob for anti-spam: `[wireLen2][wire][uLen1][username][pub65][cert64][sig64]` where `sig=sign(priv, GZCHAT|username|base64(wire))` and `cert=sign(authorityPriv, GZCERT|username|pubB64)`. Receiver verifies `GZCERT` against pinned `authorityPub` (`kAuthorityPubPref`) then `GZCHAT` before `decodeChatWire`. Unsigned legacy still shown as `UNVERIFIED` during rollout.
- **Landmark `0x08`:** `[lat4 lon4 type1 expiry4 labelLen label idLen id pub65 cert64 sig64]` with `sig=sign(priv, GZANN1|lat7|lon7|type|expiry|label)` (7-decimal). Verifier drops unverified/fake officer pins; `officialLandmarks` only holds verified.
- **Provision `GZ1` QR:** `v2` envelope `{v,t,exp,nonce,data,cert,ak,sig}` where `sig=sign(authorityPriv, GZPROV|v|t|exp|nonce|canonicalData)` and `data` includes `cert`. First QR pins `ak` as root; later QRs must have valid `sig` against that root or are `fake account blocked`.
- **Ledger/SOS** (next): `GZSOS`/`GZLEDGER` same `GZCERT` pattern planned; currently `0x05`/`0x01` are plaintext + dedup only.

## 5. Flooding

1. Encode → advertise. 2. Scan → magic/CRC/type. 3. Dedup `sender<<16|seq` LRU 500. 4. Drop if `TTL<=1`. 5. Rebroadcast `hop+1` (chat `3×` with dedupKey reuse so missed peers catch 2nd copy, seen peers drop). `chat` single-chunk is `persistent:true` 12s so a 9s `NOMINAL` sleeper wakes into it.

## 6. Radio governor

| Tier | When | Scan |
|---|---|---|
| ALERT | SOS live (90s) | continuous |
| BURST | new peer *or any* `chat`/`announce` (12s lease) | 3s/400ms |
| NOMINAL | signed-in, quiet | 3s/9s |
| STANDBY | anonymous | 3s/27s |

Jitter breaks phase-lock. Linux HQ `CONTINUOUS` (0ms). `chat` screen `boostScan` forces `BURST` 15s.

## 7. Airtime — one slot, 32-deep queue

Sticky persistent (heartbeat/SOS or single-chunk chat 12s) + rotate queue `400ms` fast drain (native) / `2s` (BlueZ) / `WinRT` publisher. `BlueZ` `InProgress` guard prevents `startDiscovery` spam. `Windows` `WinMeshAdapter` now full TX/RX via `BluetoothLEAdvertisementPublisher` patch.

Heartbeat every 10s: SOS wins, else `announce+identity` every 3rd tick `ledger-sync-req`. Single-chunk chat dwells 12s, multi-chunk 3× paced `500ms` + `800ms` gaps, depth wait `≤4` or `8s`.

## 8. Peer lifecycle

Node `id→state` (lat/lon, severity, RSSI, hops, lastSeen, username). SOS lease 90s, sweep 15s drops >2min silent. Position fallback median of GPS peers, >3× median rejected. GPS movement-gated 25-sample variance, 10s refetch floor.

## 9. Limitations

| Limitation | Detail | Mitigation |
|---|---|---|
| 22B/frame | Caps per-frame | Bulk via QR/Wi-Fi, 11B chunking |
| 16-bit ids | Collisions >few hundred | Camp scale |
| Plaintext | `SOS`/`ledger` still unsigned | Next: `GZSOS`/`GZLEDGER` signed as `GZCHAT` |
| Congestion | 3 channels, legacy interval floors | Governor + 12s sticky + 3× |
| Windows adv | Needed patch | `tool/patches/windows_ble_advertise` |

## 10. Roadmap

Per-frame `AEAD` + `GZSOS`/`GZLEDGER` signatures, GATT bulk, adaptive TX power.

---

## Layman Terms

Phones gossip by shouting Bluetooth blips. Each blip is tiny; rich stuff moves by barcode/Wi-Fi. A hop counter and fingerprint stop endless echo. Battery: listen hard in emergency, nap otherwise, with one long-held shout for short chats so sleeping phones wake into it. Now every chat and map pin carries HQ's stamp and the author's signature — fakes are thrown away before they reach the map.
