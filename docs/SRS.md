# GridZero: Software Requirements Specification

Version: 1.0 · Status: Draft · Conformance: IEEE-830-inspired, condensed
Companion to `PRD.md`. Wire-format details in `BLE_MESH_STACK.md`.

---

## 1. Scope

GridZero is a Flutter application (Android client, Linux Command HQ) providing offline disaster-relief coordination: BLE advertisement mesh messaging, SOS triage, ration distribution against a tamper-evident ledger, and HQ provisioning/sync.

## 2. System Context

```
[Citizen phone] ~BLE~ [Officer phone] ~BLE~ [Citizen phone]
        \                |                /
         ~BLE flood mesh (TTL 5)~
                         |
              [HQ Linux laptop] --Wi-Fi hotspot link (TCP :7941)-- any phone
```

Platforms: Android 12+ (primary), Linux x64 desktop (HQ). iOS directory present but unsupported in v1.

## 3. Functional Requirements

### 3.1 Identity & Accounts
- FR-3.1.1 Roles: `citizen`, `officer`, `admin` (`lib/core/app_state.dart:39`).
- FR-3.1.2 Accounts stored per-device in SharedPreferences JSON; no cross-device login.
- FR-3.1.3 Admin login is passwordless by design; admin-terminal flag persists across app wipe (`app_state.dart:247-269`).
- FR-3.1.4 Officers are never created fresh: only promoted from existing users (`promoteToOfficer`); demotion preserves ledger history.

### 3.2 Provisioning
- FR-3.2.1 Paged QR codec `GZ1|i/n|crc32|slice`, order-independent reassembly, full-payload CRC32 (`lib/core/provision_packet.dart`).
- FR-3.2.2 Typed v2 envelope `{v:2,t:"account|family|hotspot",exp,nonce,data}`; expiry: account 24 h, family card 30 d, hotspot 10 min; nonce must be unique.
- FR-3.2.3 Account envelope carries password hash (never plaintext), optional pinHash/aadhaar/family/officerId.
- FR-3.2.4 HQ persists issued accounts at generation time (`saveIssuedAccount`).

### 3.3 Mesh Networking
- FR-3.3.1 Fixed 22-byte frame, magic `0xA5`, types: SOS `0x01`, heartbeat `0x02`, ledger-sync-request `0x03`, identity `0x04`, ledger-record `0x05`, revocation `0x06`, respond-ack `0x09` (`lib/core/mesh_packet.dart`).
- FR-3.3.2 Flooding relay with TTL/hop nibble, initial TTL 5; hop+1 on rebroadcast.
- FR-3.3.3 Dedup key `(senderId<<16)|seq`; LRU of last 500 keys (`lib/core/nonce_dedup.dart`).
- FR-3.3.4 CRC8 (poly 0x07) over bytes 0–15 validated before processing.
- FR-3.3.5 Duty-cycle governor tiers ALERT/BURST/NOMINAL/STANDBY (`native_mesh.dart:56-68`).
- FR-3.3.6 Single-advertisement slot queue (max 32 frames) with sticky persistent frame; 400 ms fast drain (`native_mesh.dart:330-463`).

### 3.4 Location
- FR-3.4.1 GPS acquisition movement-gated by accelerometer variance (25-sample window), rising-edge trigger; 2-min stale watchdog (`movement_gate.dart`, `app_state.dart:1008-1053`).
- FR-3.4.2 No-GPS devices estimate position via peer consensus: median filter of GPS-bearing peers, outliers >3× median distance rejected (`mesh_controller.dart:89-113`).

### 3.5 SOS & Response
- FR-3.5.1 SOS carries severity 1–5 + TriageFlags bitfield (MED/TRAP/WATER/FOOD).
- FR-3.5.2 Active SOS wins the advertisement slot every heartbeat (10 s).
- FR-3.5.3 Peer SOS lease 90 s; controller sweep drops peers silent >2 min.
- FR-3.5.4 Respond-ack frame re-sent every 10 s while responder radar is open; target's phone rings siren via forced speakerphone (`radar_screen.dart`, AudioAlert MethodChannel).
- FR-3.5.5 Persistent banner + OS notification deep-link to radar/HQ map focus.

### 3.6 Ration Claims & Ledger
- FR-3.6.1 Citizen QR payload JSON `{v,c,w,tok,n,ph,f}`; token = first 16 hex chars of HMAC-SHA256(K, window‖id), K = SHA256("gridzero:citizen:"+id), window 30 s ±1 tolerance (`lib/core/totp.dart`, `app_state.dart:citizenQrPayload`).
- FR-3.6.2 Officer verification chain: decode → derive key → verify TOTP → fallback knowledge-PIN hash compare + visual ID dialog → revocation check → family gates → append (`app_state.dart:1200-1256`).
- FR-3.6.3 Ledger record: recordId = SHA256(citizen|ration|ts)[0:24]; hash = SHA256(recordData‖prevHash); genesis anchor SHA256("GridZero-Genesis-Anchored") (`ledger_store.dart`).
- FR-3.6.4 Append requires prevHash == local tail; unique index rejects same (citizen, ration-code, day) (`sqlite_ledger.dart`).
- FR-3.6.5 Officer signature ECDSA P-256 deterministic RFC-6979, 64-byte r‖s + 65-byte pubkey, stored locally only (`officer_sign.dart`).
- FR-3.6.6 Revocations (STOLEN/SUSPEND/CLEAR) persisted + diffused as type `0x06`; revoked cards refuse claims.
- FR-3.6.7 Mesh merge into side-table `sync_records`; original hashes preserved verbatim; local chain never rewritten; cross-officer double-claims rejected at merge (`mergeRecord`).

### 3.7 Face Enrollment
- FR-3.7.1 MobileFaceNet tflite inference; ML Kit detect → eye-centered align to 112² → L2-normalized embedding stored as blob keyed by citizen id (`lib/core/face_enroll.dart`).
- FR-3.7.2 Offered once post-provisioning; re-enrollable in Settings; synced to HQ only during explicit DB exchange.

### 3.8 Bulk Sync
- FR-3.8.1 Raw TCP port 7941, framing `GZSYNC1|sha256hex|length\n` + bytes; sha256 verified both directions; single connection exchanges both ways (`lib/core/db_sync.dart`).
- FR-3.8.2 HQ hosts virtual AP (`ap0` + hostapd/dnsmasq, subnet 192.168.51.x) via nmcli; phone joins via platform Wi-Fi suggestion channel; credentials purged after exchange (`linux_network.dart`, MainActivity.kt channel `gridzero/link`).
- FR-3.8.3 Snapshot = records + revocations + officer registry + family cards + face embeddings; import merges without rewriting local chain (`exportSnapshot/importSnapshot`).

### 3.9 UI Shell
- FR-3.9.1 Role-dependent navigation: Admin tabs HQ/Users/Officers/Sync/Register/Settings; Citizen(+Officer) tabs Citizen/Map/[Officer]/Settings (`shell.dart`).
- FR-3.9.2 Radar: compass bearing + GPS distance, RSSI-range fallback with explicit "no GPS" honesty hint.
- FR-3.9.3 Maps: OSM tiles with offline grid fallback; HQ adds Gaussian triage heatmap (`dashboard_screen.dart:_HeatmapPainter`).
- FR-3.9.4 DANGER ZONE wipes ledger + prefs + regenerates device id.

## 4. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-1 Performance | SOS visible to direct peers < 3 s; 3-hop < 15 s. Heartbeat period 10 s. |
| NFR-2 Battery | Duty-cycle governor caps scan windows per tier; NOMINAL ≈ 3 s scan / 9 s sleep. |
| NFR-3 Reliability | CRC8 wire check; dedup LRU-500; store-and-forward pending-record push on peer discovery. |
| NFR-4 Integrity | Hash-chained ledger; daily duplicate guard; sha256 sync framing; CRC32 provisioning. |
| NFR-5 Auditability | ECDSA signatures with `[SIG✓/✗/·]` badges in HQ audit log. |
| NFR-6 Portability | Graceful degradation on Linux (no GPS/camera-capture/notifications) and feature-absent phones. |
| NFR-7 Privacy | Biometric embeddings local-only until explicit sync; directories show roles/ids, never hashes. |

## 5. Security Model (current state)

- Implemented: hash chain, RFC-6979 ECDSA claim signing, TOTP rotation, PIN-hash fallback, nonce dedup, CRC checks, provision envelope expiry/nonce, sha256 sync integrity.
- Known gaps (accepted for v1 air-gapped threat model): mesh frames plaintext and unauthenticated (any peer can forge SOS/claim/revocation frames); DB sync has no TLS or peer auth: hash is integrity only; TOTP key derivable from public citizen id, so PIN fallback is the real check; officer private keys stored plaintext in sqlite; signature scope excludes claim units/familyId; single-linear chains diverge across devices with no global ordering; ADMIN is passwordless by design (physical-possession trust).

## 6. Data Dictionary (essentials)

| Entity | Fields |
|---|---|
| Account | username, role, passwordHash, pinHash?, aadhaar?, familyId?, citizenId? |
| LedgerRecord | recordId(24 hex), citizenId, rationCode, claimedAt, officerId, prevHash, currentHash, sig?, pubkey?, units |
| Revocation | citizenIdTag(4B)+digestTag, action(STOLEN/SUSPEND/CLEAR), origin, ts |
| MeshNode | id(u16), lat/lon, severity, rssi, hops, lastSeen, username, role |
| FaceEmbedding | citizenId → float32 vector blob (local-only until sync) |

## 7. Acceptance Criteria

- AC-1: 3 phones relay an SOS 2 hops away within 15 s with Bluetooth-only radios.
- AC-2: Same citizen + same ration code scanned twice same day by two different officers → second claim rejected.
- AC-3: Tampering any byte of a synced ledger record fails merge or breaks chain linkage.
- AC-4: Screenshot of citizen QR used after 90 s fails TOTP verification.
- AC-5: Full HQ↔phone exchange completes both directions in one connection; corrupted frame aborts transfer.
- AC-6: Wiping app data on HQ machine restores ADMIN role on next boot.

---

## Layman Terms

This is the builder's blueprint. It says exactly what each part must do:

- **Who uses it:** three kinds of people: ordinary camp residents (citizens), aid workers with scanners (officers), and one control-desk laptop (admin).
- **Getting in:** nobody signs themselves up; the control desk prints scannable codes that hand out identities, like issuing wristbands at a festival gate.
- **The walkie-talkie network:** phones shout short messages over Bluetooth; each message has a "jump counter" so it dies after 5 hops instead of bouncing forever, plus a fingerprint check so garbled messages get dropped and repeats get ignored.
- **Crying for help:** SOS messages say how bad things are and what's needed; nearby responders' answers make the person's phone ring loudly.
- **Food queue:** the changing barcode stops photo-copying; the receipt book can't be edited quietly; the same person can't draw the same item twice in one day even from two different workers.
- **Moving data to base:** one tap makes the laptop open its own little Wi-Fi bubble; the phone steps in, both sides swap complete copies, checksums prove nothing got mangled, and the Wi-Fi password is thrown away afterwards.
- **Honesty section:** the spec openly lists what's *not* protected yet (messages aren't encrypted, so a tech-savvy eavesdropper could read them): like a shop that locks the till but leaves the window open, documented so everyone knows.
