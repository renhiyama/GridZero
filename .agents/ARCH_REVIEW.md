# ARCH_REVIEW — Sector provisioning + face-verification proposal

Verdict: **YES, it works, and it matches this codebase's existing shape.** The
22-byte gossip, offline-first ledger, and QR-based identity already exist.
What the proposal adds is a pre-disaster enrollment DB + offline field
verification. Feasible. These are the real risks:

## Sound parts (keep)
- Salted member_id + pin_hash: correct zero-knowledge shape; the codebase
  already stores pin_hash this way.
- AES-256-GCM sector slice + ECDSA-P256 signature + hardware Keystore/Keychain:
  standard, no trap.
- 128-d MobileFaceNet Int8 BLOB (round(v×127)) + dot-product match: a
  known-good quantized face path. 0.75 cosine threshold is plausible.
- 22-byte allocation gossip: the existing `ledgerRecord` (0x05) frame is
  already this. Integration is the easy part.
- ~55MB / 2-3s over 802.11ac: fine if the link is clean; expect 5-10s in
  practice on phone hotspots — target is still met.

## Risky parts (fix before building)
1. **QR is a capture-the-sector key.** `sector_key_enc` + `wifi_psk` sit on a
   screen. Anyone who photographs the QR can join the hotspot and pull the
   whole encrypted sector DB if they also get the key. Mitigations: one-time
   PSK rotation, TLS with the officer cert, or pairing (officer scans first,
   HQ shows the key QR only after a handshake).
2. **iOS cannot auto-join WiFi.** No API to programmatically join `GRIDZERO_HQ_AP`.
   Android 10+ can (`WifiNetworkSpecifier`); iOS users must join manually.
   The 2-camera QR transfer (task #10) is therefore not a gimmick — it is the
   only cross-platform zero-touch path. Keep it.
3. **Liveness ≠ proof.** ML Kit blink/head-turn beats printed photos but not
   a video replay. Acceptable for relief allocation; do not claim
   "spoof-proof" in any doc.
4. **Face bias.** Int8 quantization + 0.75 threshold must be validated across
   skin tones/lighting or good people get rejected at the gate. Test set
   matters more than the model choice.
5. **Offline conflicts.** Two officers allocating the same ration card in
   different camps = double spend. The existing hash-chain ledger handles
   ordering, but the proposal must define a winner rule (e.g., first
   claimedAt wins, reconcile on next sync) or relief goes twice.
6. **Sector key lifetime.** Lost officer phone = the sector key was usable in
   memory; hardware Keystore only protects at rest. Define a re-key/rotation
   story or accept the risk in the threat model.

## Build order suggestion
1. #9 face enroll at admin (model + ML Kit) — the biggest unknown is the
   model asset, not the code.
2. #10 2-camera QR transfer — replaces the fragile family-QR.
3. #12 officer flow — reuse admin's flow.
4. #11 DB pull — only after #10's optical path works, as the high-speed tier.
5. Wire the allocation-gossip + conflict rule last.