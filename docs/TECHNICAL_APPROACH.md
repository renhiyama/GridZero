# GridZero: Technical Approach

Version: 1.1 · Status: Active · Pure prose

---

## 1. Architecture Overview

Three-layer Flutter application, one codebase, three form factors (Android phone, Linux HQ primary, Windows HQ via WinRT patch):

1. **UI layer**: role-adaptive shell (`shell.dart`) swapping tabs per `citizen`/`officer`/`admin`; `MeshMap` shared across HQ `dashboard_screen.dart:285`, citizen `map_screen.dart:35`, officer `officer_screen.dart:640`. Chat `MESH` tab and `OFFICIAL LOCATIONS` pins are the same widget everywhere.
2. **Application core**: `AppState` owns accounts (HQ-signed), SOS, heartbeat, claim verification, `GZCERT`/`GZCHAT`/`GZANN1` signing, GPS, chat codec, and landmark registry; UI reacts to its streams.
3. **Services layer**: swappable adapters behind `MeshAdapter`/`LedgerStore`: `NativeMeshAdapter` (Android `flutter_blue_plus` + `ble_peripheral_plus`), `BluezMeshAdapter` (Linux D-Bus), `WinMeshAdapter` (Windows `BluetoothLEAdvertisementPublisher` patch), `SqliteLedgerStore`/`MemoryLedgerStore`, `FlutterLiteCamera` (Linux V4L2) vs `camera_windows` (Windows).

Adapter pattern is load-bearing: same `MeshController`/`MeshPacket` code runs on all radios.

## 2. Key Technical Decisions

| Decision | Choice | Why |
|---|---|---|
| Mesh transport | BLE **advertisements**, not GATT | Connectionless, hundreds of peers, no pairing |
| Frame | 22-byte binary `0xA5` + CRC8, 11B chunk `11` | Legacy 31B budget, binary beats JSON |
| Routing | TTL 5 + LRU dedup 500 | Zero state, camp-scale |
| Ledger | Local hash chain, additive merge | Offline, never rewrite history |
| Claim auth | TOTP 30s + PIN-hash + face | Screenshot dies ≤90s, fallback honest |
| Signatures | ECDSA P-256 deterministic, `deriveSigningKey(hash)` + `GZCERT`/`GZPROV`/`GZCHAT`/`GZANN1` | Same key on HQ and device without private transport; blocks fake accounts/bots |
| Bulk sync | `GZSYNC1|hash|len` TCP `:7941` two-way | No HTTP/certs; HQ hosts `GZ-<USER>` `ap0` `192.168.51.1/24` via `hostapd`/`dnsmasq`/`nft` (Linux) or `netsh` client + `WinRT` publisher (Windows) |
| Provisioning | Paged `GZ1|crc` QR + `v2` envelope `{v,t,exp,nonce,data,sig,cert,ak}` | HQ-signed (`GZPROV`), cert binds pub to `id`, `ak` pins root; `24h` QR only, account never expires |
| Chat | 220B wire (251 packed English via 7-bit `chat_codec.dart`) + `GZCHAT` signed `wireLen|wire|uLen|user|pub|cert|sig`, sticky 12s + 3× repeat | Sleeping 9s `NOMINAL` still catches single-chunk |
| Face | MobileFaceNet 112² local only | No cloud, sync only via explicit Wi-Fi |
| Windows | `xwin` SDK + `BluetoothLEAdvertisementPublisher` C++ patch | Full TX/RX, same rotation/pacing |

## 3. Subsystem Approaches

### 3.1 Mesh
Single slot + 32-deep rotate queue; governor `ALERT`(SOS continuous)/`BURST`(12s on new peer or any `chat`/`announce`)/`NOMINAL`(3s/9s)/`STANDBY`(3s/27s). `chat` single-chunk sticky 12s + 2 quick re-airs; multi-chunk 3× paced (500ms + 800ms gaps) with dedupKey reuse. `BlueZ` `InProgress` guard + `BlueZ`/`Win` patches reapply via `tool/apply_patches.sh`. See `BLE_MESH_STACK.md`.

### 3.2 Ledger & claims
Append-only chain anchored at `GridZero-Genesis-Anchored`; daily duplicate guard via unique index; `sync_records` side table preserves hashes; officer `ECDSA` gives non-repudiation; `GZCERT`-verified `chat` now blocks spam.

### 3.3 Sync
One TCP does two-way `GZCERT`-aware exchange; `linux_network.dart:158` `sudo -n` ap0 + `windows_network.dart` `netsh`; `gridzero/link` channel, purged after.

### 3.4 Identity & provisioning
HQ is sole issuer. `deriveSigningKey(hash)` is deterministic on both sides; `certifyKey` signs `GZCERT|id|pubB64` with `authorityPriv` (`kAuthorityPrivPref`). `encodeAccountProvision` adds `cert` + `ak` + `sig = GZPROV|v|t|exp|nonce|canonicalData`. `provisionAccount` verifies `sig` against pinned `authorityPub` and `cert` against derived `pub` — unsigned QR rejected once a root is pinned.

### 3.5 Sensing
Movement-gated GPS (25-sample variance, 10s floor), compass bearing+distance, RSSI fallback, `chat`/`landmark` as `MeshMap` shield pins.

## 4. Technology Stack

- **Framework:** Flutter/Dart, Android+Linux+Windows.
- **BLE:** `flutter_blue_plus`/`ble_peripheral_plus` (Android), `bluez`/`dbus` (Linux), `BluetoothLEAdvertisementPublisher` (Windows via patch).
- **Crypto:** `pointycastle` ECDSA P-256 + `crypto` SHA256/HMAC, `deriveSigningKey` from `sha256('gridzero:sign:$hash')`.
- **Storage:** `sqflite_common_ffi` (desktop), `sqflite` (Android), `SharedPreferences` for `accounts` + `cert_sig_*` + `authority_pub`.
- **Vision:** `MobileFaceNet` + `google_mlkit_face_detection` (mobile), `flutter_lite_camera` + `zxing2` (Linux), `camera_windows` (Windows).
- **Maps:** `flutter_map` OSM + `geolocator`/`flutter_compass`/`sensors_plus`.

## 5. Testing Strategy

`166 +1` tests (`provision_sign_test` added): wire round-trips, CRC, LRU, TOTP, ledger, `GZCERT`/`GZPROV`/`GZCHAT` verify, `7-bit` pack, `chat` sticky, `BlueZ` guard, flood with fake mesh harness. Widget tests for `chat` order + auto-scroll, `MeshMap` pins. `flutter analyze` clean is gate; `tool/apply_patches.sh` idempotent. 2-device live mesh (Linux `41793` + Android `32875`) verified `chat` `3×` and `landmark` `GZCERT`.

## 6. Known Technical Debt (v1.1)

- `SOS` beacons and `CompactRecord` ledger frames are still plaintext/unsigned (next: `GZSOS`/`GZLEDGER` same `GZCERT` pattern as `GZCHAT`).
- DB sync has hash integrity but no TLS (air-gapped Wi-Fi, acceptable).
- `ADMIN` passwordless is physical-possession trust.
- Officer/citizen priv derived deterministically from `hash` and stored as `cert` — at-rest encryption planned.
- Per-device linear chains lack global ordering.
- 16-bit `nodeId` caps camp scale.

---

## Layman Terms

One kitchen, many waiters. The kitchen knows who is who and what is signed; waiters just shout on the right radio (Android, Linux, Windows) without the kitchen caring. Food tickets tick every 30s; the receipt book is glued and signed. Now every chat and every map pin is also signed with the same wristband key HQ stamped — fakes are thrown away, and a single short message is held up long enough that even a sleeping phone wakes into it.
