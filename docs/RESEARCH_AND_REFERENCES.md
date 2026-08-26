# GridZero: Research & References

Version: 1.0 · Status: Draft · Pure prose

---

## 1. Problem-Space Research

- **Disaster connectivity failure patterns**: post-event telecom restoration consistently lags the response window; ITU and UN OCHA field reports document that the first 72 hours of major disasters (Nepal 2015, Kerala floods 2018, Turkey–Syria 2023) run almost entirely without cellular data. This motivates the air-gapped design assumption.
- **Aid leakage literature**: NGO and academic studies of relief distribution repeatedly report significant diversion/duplicate-drawing losses in paper-based systems; identity-linked, auditable distribution is the standard recommended countermeasure.
- **Mesh networking in crisis response**: projects such as Serval Mesh, Bridgefy, Briar, and firechat-style ad-hoc networks established that store-and-forward phone mesh is viable; documented weaknesses of those systems (unauthenticated frames, traffic-analysis exposure) directly informed GridZero's honest gap register.

## 2. Protocol & Standards References

| Topic | Reference |
|---|---|
| Bluetooth Core Specification: advertising packets, AD structures, 31-byte legacy payload, Manufacturer Specific Data (type 0xFF) | Bluetooth SIG, Core Specification v5.x, Vol 3, Part C |
| Company identifiers (0xFFFF = Bluetooth SIG test/reserved) | Bluetooth SIG Assigned Numbers document |
| BLE security posture of advertisement payloads (plaintext by design) | NIST SP 800-121 Rev. 2, *Guide to Bluetooth Security* |
| Controlled flooding with TTL + duplicate suppression | Classic ad-hoc routing literature (RFC 3561 AODV background; epidemic dissemination algorithms) |
| TOTP time-based one-time passwords (30 s windows, ±step tolerance) | RFC 6238 |
| HMAC key construction | RFC 2104 |
| Deterministic ECDSA (removes nonce-randomness failure class) | RFC 6979 |
| SHA-256, hash chaining / tamper evidence | FIPS 180-4; blockchain-style chain-of-blocks lineage |
| P-256 curve recommendation | NIST SP 800-186 |
| CRC-8 (poly 0x07) | ISO/IEC standards lineage of CRC-8-ATM |

## 3. Technology References

- **Flutter/Dart** cross-platform framework: Google documentation; chosen for single-codebase Android + Linux delivery.
- **MobileFaceNet**: Wang et al., *MobileFaceNets: Efficient CNNs for Accurate Real-Time Face Verification*, 2018: the 112×112 embedding model class used for on-device biometrics.
- **ML Kit face detection**: Google on-device detection API used pre-alignment.
- **SQLite / sqflite**: reference RDBMS for embedded local-first storage.
- **BlueZ**: Linux official Bluetooth protocol stack; D-Bus advertising API used by the HQ adapter.
- **hostapd / dnsmasq / NetworkManager (nmcli)**: standard Linux tooling for software access-point hosting during bulk sync.
- **OpenStreetMap raster tiles**: offline-capable map basemap with no API-key dependency.

## 4. Domain Precedents

- **Apple Find My network**: demonstrates anonymous, encrypted advertisement-relay at planetary scale; validates "data in the advertisement" architecture.
- **COVID contact-tracing (Google Apple Exposure Notification)**: validated BLE rolling-proximity identifiers and rotating tokens as public-acceptable privacy patterns; GridZero's rotating ration QR follows the same rotation principle.
- **UNHCR biometric registration (BIMS)**: precedent and cautionary tale for camp biometrics; informs GridZero's local-only-until-explicit-sync stance.
- **India's Public Distribution System digitisation**: ration-card token flows and the duplicate-draw problem GridZero's daily guard addresses.

## 5. Security Literature Informing the Threat Model

- Physical-possession-as-trust-root models for disconnected provisioning (smart-card issuance practice).
- Known attacks on unauthenticated flooding meshes: message injection, replay, Sybil node injection: all present in GridZero's documented v1 gaps, all requiring frame-level signatures/AEAD to close.
- Static-salt hashing vs per-user salt (OWASP Password Storage Cheat Sheet): flagged as hardening debt in the current PIN/password scheme.
- Side-table merge strategies for distributed logs (CRDT add-wins intuition) behind the never-rewrite-local-chain sync rule.

## 6. Internal Companion Documents

- `docs/PRD.md`: product requirements
- `docs/SRS.md`: software requirements specification
- `docs/BLE_MESH_STACK.md`: wire-format and radio-stack reference
- `docs/TECHNICAL_APPROACH.md`: architectural decisions
- `docs/FEASIBILITY_AND_VIABILITY.md`, `docs/IMPACT_AND_BENEFITS.md`

---

## Layman Terms

This page is the bibliography: proof the design wasn't invented from thin air:

- **The problem is real:** every big disaster study shows phone networks die first while help is still needed most; aid handouts on paper get cheated in well-known ways.
- **The tricks are borrowed:** the "shout tiny messages over Bluetooth" idea is how Apple's Find My and COVID contact-tracing apps work; the "code that expires in 30 seconds" is the same trick as bank security tokens; the "receipts glued into a chain" is the same idea behind blockchain, minus the hype; the face-matching model is a published research paper from 2018.
- **The rules are official:** the size limits of Bluetooth shouts come from the official Bluetooth rulebook; the password-token maths comes from published internet standards (the RFC documents); the checksum recipes are decades-old international standards.
- **Past failures were studied:** earlier disaster chat apps were criticised because anyone could inject fake messages: that exact criticism is written into this project's honesty list as the top fix for version 2.
- **And the rest is internal:** the other six documents in this folder describe what we're building and why each piece is the way it is.
