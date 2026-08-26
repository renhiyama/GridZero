# GridZero: Product Requirements Document

Version: 1.0 · Status: Draft · Owner: Project Team

---

## 1. Vision

Disasters destroy cell towers before they destroy people. GridZero lets a disaster-relief camp run entirely without internet or cellular coverage: citizens broadcast SOS beacons, officers verify identities and distribute rations against a tamper-evident ledger, and a Command HQ laptop sees the whole camp on one map: all over phone-to-phone Bluetooth Low Energy mesh.

**One line:** an air-gapped, offline-first relief-camp operating system that fits in responders' pockets.

## 2. Problem

- After floods/earthquakes/cyclones, connectivity dies but aid must flow.
- Paper ration lists get lost, duplicated, forged; double-draws go undetected.
- SOS calls have no channel; triage is shouting and guesswork.
- HQ has no live picture of who needs help, where, or how badly.

## 3. Users & Roles

| Role | Device | Core jobs |
|---|---|---|
| **Citizen** | Android phone | Fire SOS with severity + needs flags; show rotating identity/ration QR; view own card status |
| **Officer** | Android phone | Scan citizen QR to issue ration claims; flag/revoke stolen cards; respond to SOS; sync ledger to HQ |
| **Admin / Command HQ** | Linux laptop | Provision all accounts via QR; host Wi-Fi link; view dashboard: live mesh map, triage heatmap, audit log, officer registry |

Accounts are never self-created: every identity is issued by HQ through provisioning QR codes (physical trust handoff).

## 4. Feature Requirements

### FR-1: Offline Mesh Networking
- Phones form a BLE advertisement mesh; messages flood peer-to-peer (TTL 5).
- Frame types: SOS, heartbeat/announce, identity, ledger record, revocation, respond-ack, ledger-sync-request.
- Duplicate suppression, CRC integrity check, duty-cycle governor to save battery.

### FR-2: SOS & Triage
- Citizen raises SOS: severity 1–5 + needs bitfield (medical / trapped / water / food).
- Beacon propagates across the mesh within seconds; peers see it on radar/map with bearing & distance.
- Officers tap "respond"; responder count and audible acknowledgement ring on citizen's phone.
- SOS auto-expires (lease) if citizen goes silent or explicitly clears it.

### FR-3: Ration Distribution
- Citizen shows a QR that rotates every 30 s (TOTP-style) so screenshots/copies are useless.
- Officer scans → verifies → claim appended to hash-chain ledger signed with officer's device key.
- Daily duplicate claims rejected; family cards support fractional draws (0.25–1.0 units) against a daily cap.
- Revoked/suspended cards refused at scan time; revocations diffuse over the mesh.

### FR-4: Tamper-Evident Ledger
- Every claim chained to the previous via SHA-256; officer signature (ECDSA P-256) gives non-repudiation.
- Records merge across devices without rewriting anyone's local chain; conflicts rejected.

### FR-5: Provisioning & Identity
- HQ issues accounts/family cards/officer promotions as multi-page CRC-protected QR envelopes with expiry + nonce.
- Optional face enrollment (on-device MobileFaceNet embedding) for stronger ID at scan time.

### FR-6: Command HQ Dashboard
- Live map of every mesh node, SOS heatmap, node list with role/severity/hops.
- Full audit log with signature badges; user/officer directories; revocation panel.

### FR-7: Bulk Sync
- One-tap two-way database exchange between any phone and HQ over a local Wi-Fi hotspot link (integrity-hashed framing), including face embeddings.

## 5. Non-Goals (v1)

- Internet/cloud connectivity, remote HQ.
- iOS parity (Android + Linux HQ only).
- End-to-end encrypted mesh payloads (roadmap: see Security notes).
- Multi-camp federation.

## 6. Success Metrics

| Metric | Target |
|---|---|
| SOS propagation across 3-hop camp | < 15 s |
| Ration claim scan-to-ledger time | < 10 s |
| Battery drain (citizen idle, mesh on) | < 8%/day |
| Ledger daily duplicate rejection | 100% |
| Camp of 200 devices stable without crash | 24 h |

## 7. Constraints

- Zero infrastructure assumption: no towers, no internet, possibly no mains power.
- Commodity Android phones only; HQ is any Linux laptop with Bluetooth + sudo.
- All cryptography local; no external services, no telemetry.

## 8. Risks (top-level)

- BLE advertisement payload ceiling limits per-frame data (see `BLE_MESH_STACK.md`).
- Mesh wire format currently unencrypted; spoofable frames possible until v2 crypto lands.
- 16-bit node IDs collide beyond ~few hundred concurrent nodes.

---

## Layman Terms

Imagine a flood has knocked out every phone tower. This app turns everyone's phones into walkie-talkies that talk to each other over Bluetooth, hopping message-to-message like a bucket brigade until the whole camp is connected: no internet needed.

A person who needs help presses an SOS button saying how bad it is and what they need (medicine, rescue, water, food). Every nearby phone passes that cry for help along until it reaches aid workers, who see exactly where to go on a map and can press "help is coming": which makes the stranded person's phone actually ring.

When food is handed out, the person shows a barcode on their phone that changes every 30 seconds (like a bank token), so nobody can photograph someone else's barcode and use it twice. The aid worker scans it and the "transaction" gets locked into a chain of records that can't secretly be edited: like a receipt book where each page is glued to the previous one.

A head-office laptop sees the whole camp: who's SOS-ing, where, who got rations, and whether any records look fake. New IDs are created only by this head office and handed out as scannable codes in person. Everything works even if the outside world has completely disappeared.
