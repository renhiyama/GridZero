# GridZero: Technical Approach

Version: 1.0 · Status: Draft · Pure prose

---

## 1. Architecture Overview

Three-layer Flutter application, one codebase, two form factors (Android phone client, Linux desktop HQ):

1. **UI layer**: role-adaptive shell that swaps tab sets per role (citizen / officer / admin), Material 3 dynamic theming, radar and map visualisations.
2. **Application core**: a central app-state controller owning accounts, SOS state, heartbeat scheduling, claim verification, revocation handling, and GPS acquisition; all UI reacts to its streams.
3. **Services layer**: swappable adapters behind stable interfaces: mesh radio adapters (Android native BLE vs Linux BlueZ), ledger backends (SQLite vs in-memory fallback), camera scanners (mobile plugin vs V4L2+decoder on desktop).

The adapter pattern is the load-bearing decision: the same protocol code runs on phone radios and desktop BlueZ without branching the business logic.

## 2. Key Technical Decisions

| Decision | Choice | Why this over alternatives |
|---|---|---|
| Mesh transport | BLE **advertisements**, not GATT connections | Connectionless flooding scales to hundreds of unpaired devices; connections need pairing UX and per-peer state |
| Frame design | Fixed 22-byte binary frame with CRC8 | Fits legacy adv payload with room to spare; binary beats JSON at this budget |
| Routing | Controlled flooding, TTL 5 + LRU dedup | Zero routing state; simplest correct protocol for dense small-area camps |
| Ledger | Local-first hash chain per device | Works fully offline; merges are additive, never rewrite local history |
| Claim auth | Rotating TOTP-style QR + PIN-hash fallback + visual check | Screenshots/replays die in ≤90 s; fallback works when cameras fail |
| Signatures | ECDSA P-256, deterministic RFC-6979 | Standard curve, small keys, no RNG-failure class of bugs thanks to determinism |
| Bulk sync | Raw TCP with hash-checked framing over device-hosted Wi-Fi AP | Deliberately not HTTP: sidesteps Android cleartext policy and certificate problems with zero infrastructure |
| Provisioning | Multi-page CRC32 QR envelopes with expiry + nonce | Physical handoff is the trust root; QR needs no network at all |
| Face biometrics | On-device embedding only (MobileFaceNet), synced solely via explicit exchange | No cloud, no template server; privacy-preserving by construction |

## 3. Subsystem Approaches

### 3.1 Mesh
Single-advertisement slot with a rotating queue keeps airtime fair; a context-aware duty-cycle governor (alert / burst / nominal / standby) reconciles responsiveness with battery life. Peer consensus positioning lets GPS-less phones participate on the map. See `BLE_MESH_STACK.md` for the full wire contract.

### 3.2 Ledger & claims
Each device owns an append-only chain anchored at a fixed genesis. Appends validate previous-hash linkage and enforce a daily duplicate guard via a database unique index. Cross-device records arrive as compact wire summaries into a side table: original hashes preserved byte-for-byte, so merging never fabricates history. Officer signing gives non-repudiation on the signer's own device; HQ displays signature-verification badges during audit.

### 3.3 Sync
One TCP connection performs a two-way exchange: each side sends its snapshot framed with length + SHA-256, verified before import. HQ brings up a virtual access point through system networking tools; phones join via platform Wi-Fi suggestion APIs and credentials are purged immediately after. A legacy reverse path (phone hosts hotspot, HQ joins) covers field offices without the HQ laptop.

### 3.4 Identity & provisioning
HQ is the sole issuer. Envelopes are typed (account / family card / hotspot), expiring, and nonce-guarded against re-issue. Officers are promoted, never minted fresh, preserving their audit trail. Family cards carry fractional daily caps enforced locally at claim time.

### 3.5 Sensing
Accelerometer-gated GPS (fix only when movement detected), compass bearing + distance for the responder radar with RSSI-based range estimation as honest fallback, and on-device face embeddings aligned and normalised entirely locally.

## 4. Technology Stack

- **Framework:** Flutter/Dart (single codebase, Android + Linux targets).
- **BLE:** platform plugins for Android central/peripheral roles; BlueZ over D-Bus on Linux.
- **Crypto:** SHA-256, HMAC-SHA256, ECDSA P-256 via a pure-Dart cryptographic library (no OS keystore dependency → deterministic cross-platform behaviour).
- **Storage:** SQLite everywhere (FFI on desktop), SharedPreferences for account store.
- **Vision:** bundled MobileFaceNet model + ML Kit detection on mobile; V4L2 capture + software QR decoding on Linux.
- **Maps/positioning:** OpenStreetMap raster tiles with offline grid fallback; geolocation + compass + accelerometer sensor suite.

## 5. Testing Strategy

Unit suites cover every pure core: wire codec round-trips, CRC vectors, dedup LRU, TOTP windows, ledger append/merge/tamper rejection, signature verification, provisioning reassembly, family-cap gates, flood behaviour under synthetic mesh fakes. Widget tests cover screens and shell navigation. The mesh adapter interface enables a full fake-mesh test harness without real radios.

## 6. Known Technical Debt

- Wire frames unencrypted/unauthenticated (roadmap: AEAD + signatures post key-provisioning).
- Signature scope omits claim amounts/family linkage.
- Officer private keys plaintext at rest; at-rest encryption planned.
- Per-device linear chains lack global ordering across devices (no consensus).
- 16-bit node ids limit camp scale.

---

## Layman Terms

Think of the app as built like a restaurant with one kitchen and many waiters. The "kitchen" is the brain that knows who's who, who's SOS-ing, and what's in the receipt book. The "waiters" are plug-in parts: one waiter knows how to shout over Bluetooth on Android phones, another knows how to do it on Linux laptops; swap them and the kitchen never notices.

Big choices, in plain words:

- Phones gossip by shouting short Bluetooth bursts rather than holding hands with each connection: because you can shout to everyone at once.
- Every message is squeezed into a tiny fixed envelope so it always fits what Bluetooth allows.
- Each aid laptop/phone keeps its own glued-together receipt book; copies from neighbours get pasted into a side appendix, never rewriting the original pages.
- Food tickets change code every half minute, so photos of someone's ticket go stale fast.
- Handing out new IDs happens face-to-face with scannable codes: the handshake itself is the security.
- Big file copying between phone and laptop happens inside a private little Wi-Fi bubble the laptop creates, with checksums proving nothing got scrambled.
- Everything was tested piece by piece with pretend radios, so most of the logic can be proven correct without a single real Bluetooth chip in the room.
- The team openly lists shortcuts taken for version 1 (messages not yet encrypted, keys stored plainly): debts written on the whiteboard, not hidden under the rug.
