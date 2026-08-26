# GridZero: BLE Mesh Stack

Version: 1.0 · Status: Draft · Pure prose (wire-format reference)
Companion to `SRS.md` §3.3. No source references by design: this is the standalone wire contract.

---

## 1. Why an *advertisement* mesh

GridZero does not use BLE connections (GATT) between peers. Every message rides inside a **BLE advertising packet**: the same one-shot broadcast phones emit when discoverable. Consequences:

- **Connectionless:** a phone can "talk" to hundreds of neighbors without pairing, handshakes, or per-peer state.
- **Asymmetric roles are fine:** any device can be both advertiser and scanner simultaneously.
- **Lossy by nature:** broadcasts are unacknowledged; reliability comes from repetition (heartbeats) and flooding (TTL), not delivery guarantees.
- **Platform-friendly:** Android and Linux BlueZ both expose raw manufacturer-data advertising without root.

## 2. Radio capacity: what fits on air

A legacy BLE advertisement carries **31 bytes** of payload after radio headers. An AD structure spends:

| Overhead | Bytes |
|---|---|
| Structure length field | 1 |
| Type tag (Manufacturer Specific Data, 0xFF) | 1 |
| Company ID (0xFFFF, Bluetooth-reserved test ID) | 2 |
| **Available for the frame** | **≤ 27** |

GridZero uses **22 of those 27 bytes**. It deliberately targets *legacy* advertising (not the larger extended-advertising PDUs) because extended advertising support is patchy across Android chipsets and absent/awkward under BlueZ. One frame always fits one packet: no fragmentation at the radio layer, no scan-response dependence.

**Design rule this forces:** every message must say something useful in ~22 bytes. Richer data (full ledger hashes, face embeddings, account blobs) never goes over the mesh; it travels via QR codes or the Wi-Fi bulk-sync link. The mesh carries *pointers and alerts*; QR and hotspot carry *payloads*.

## 3. Frame format (22 bytes, big-endian)

| Byte(s) | Field | Notes |
|---|---|---|
| 0 | MAGIC `0xA5` | Rejects foreign advertisers instantly |
| 1 | TYPE | See table below |
| 2–3 | SENDER_ID (uint16) | Node id hash suffix |
| 4–7 | LATITUDE (int32) | Fixed point ×10⁷ (~1 cm resolution): coordinate frames only |
| 8–11 | LONGITUDE (int32) | Same encoding |
| 12 | TRIAGE_FLAGS | bit7 Medical, bit6 Trapped, bit5 Water, bit4 Food, bits3–0 Severity 1–5 |
| 13 | TTL_HOP | High nibble = initial TTL (5), low nibble = hops travelled |
| 14–15 | SEQ_NUM (uint16) | Monotonic counter, wraps |
| 16 | CRC8 | Polynomial 0x07, computed over bytes 0–15 |
| 17 | FLAGS | bit0 = "SOS cleared" marker; overloaded per type below |
| 18–21 | ALTITUDE (int32) | Centimetres; sentinel value means "unknown" |

### Frame types & payload reuse

Bytes 4–21 double as payload for frames that carry no coordinates:

| Type | Name | Bytes 4–21 carry |
|---|---|---|
| 0x01 | SOS beacon | Coordinates + triage flags + altitude |
| 0x02 | Relay status / heartbeat | Coordinates ("I'm alive, here I am") |
| 0x03 | Ledger sync request | Coordinates; asks peers for pending claims |
| 0x04 | Identity announce | Username ASCII ≤12 chars (split across three slots), role code, name length in byte 17 |
| 0x05 | Ledger record | Citizen-id 4B tag, officer-id 4B tag, claim timestamp epoch32, ration-code index (0–4 or 0xF "other"), claim units as quarter-bits in byte 17 |
| 0x06 | Revocation alert | Citizen-id 4B tag + SHA-256 digest tag, reason (stolen/suspended/cleared), issue time |
| 0x09 | Respond ack | Target node id uint16 ("I am coming to help node X") |

ID packing: ids shaped like `CIT-XXXXXXXX` pack their hex suffix into 4 bytes; anything else is hashed to a stable 4-byte tag. Full ration-item names never travel: only an index into a shared five-item list (Rice, Water, Blanket, Medicine, Fuel).

## 4. Flooding protocol

1. A device encodes a frame and starts advertising it.
2. Every scanning neighbor receives it, checks magic → CRC → type.
3. Duplicate check: key = sender id combined with sequence number, against an LRU cache of the last **500** keys. Seen before → drop silently.
4. If hop count has reached initial TTL (**default 5**) → drop.
5. Otherwise rebroadcast with hop count + 1. The frame ripples outward in rings, one ring per radio hop.

This is classical controlled-flood dissemination: zero routing state, maximal redundancy, bounded by TTL and dedup.

## 5. Radio governor (battery management)

Scanning is expensive; advertising is nearly free. The governor picks a duty-cycle tier from context:

| Tier | When active | Scan behaviour |
|---|---|---|
| ALERT | Own or peer SOS live (90 s continuous-scan lease) | Continuous scan |
| BURST | New peer discovered (12 s lease) | Fast scan, short sleeps (≈400 ms) |
| NOMINAL | Signed-in user, quiet camp | ≈3 s scan / 9 s sleep |
| STANDBY | Anonymous device | ≈3 s scan / 27 s sleep |

Random jitter breaks phase-lock (so devices don't fall into synchronized blind windows). The Linux HQ ignores duty hints: it scans continuously because it's mains-powered.

## 6. Airtime scheduling: one slot, many messages

A phone advertises **one frame at a time**. A queue (capacity 32) rotates frames through the slot: during burst drain each frame gets ≈400 ms of airtime; one "sticky persistent" frame (current coordinates announce, or an active SOS) always returns to the rotation. Failed slot swaps are peek-then-commit so nothing is silently lost.

Heartbeat cadence: every 10 s the device re-arms its slot: SOS wins if active, else announce + identity; every third tick it also requests ledger sync. Respond-acks repeat every 10 s while the responder's radar screen is open.

## 7. Peer lifecycle

- Node table tracks per neighbor: position, severity, RSSI, hops, last-seen, username, role.
- **SOS lease:** a peer SOS stays "active" 90 s after last sighting; explicit clear markers (flags bit0), non-SOS announces, or lease expiry all end the alarm.
- **Garbage collection:** a controller sweep every 15 s drops nodes silent > 2 minutes.
- **Position fallback:** GPS-less devices estimate their own location as the median of GPS-bearing neighbors' positions, rejecting outliers beyond 3× median distance. GPS itself is movement-gated (accelerometer variance triggers a fix) to save power.

## 8. Limitations & known risks

| Limitation | Detail | Mitigation today |
|---|---|---|
| Tiny payload | 22 bytes/frame caps expressiveness | Bulk data via QR + Wi-Fi sync; mesh carries alerts/tags only |
| Plaintext, unsigned | Any BLE listener can read SOS locations/usernames and can forge frames (including fake revocations) | Accepted for v1 air-gap threat model; crypto roadmap item |
| 16-bit sender ids | Collisions likely beyond a few hundred concurrent nodes | Fine for camp scale (<~500); roadmap: wider ids |
| Sequence wrap | uint16 counters wrap → stale-dedup edge cases | LRU eviction bounds damage |
| Unacknowledged radio | Broadcasts can be missed | Flooding redundancy + heartbeats + store-and-forward claim push on rediscovery |
| Congestion | Hundreds of advertisers share 3 BLE channels; legacy adv interval floors apply | Duty-cycle governor + slot rotation keep per-device airtime low |
| Revocation trust | 0x06 frames carry only a 4-byte tag + digest tag, no signature | Physical verification still required at claim time |
| BlueZ quirks | Stale advertisement handles exhaust the kernel's adv slots; handled by unregistering before re-register | HQ-only workaround |

## 9. Roadmap candidates

- Per-frame AEAD encryption + sender signatures once key provisioning exists (frames would shrink payload further; may need two-frame messages).
- GATT connection mode for officer↔HQ bulk exchange without Wi-Fi.
- Adaptive TX power / RSSI-based backoff for very dense camps.

---

## Layman Terms

Phones in the camp gossip using Bluetooth's "shout into the void" mode: the same blip your phone makes when it's discoverable: instead of formally connecting like headphones do. That trick means one phone can reach everyone nearby at once, no pairing pop-ups, no internet.

Each shout is tiny: about the size of a tweet's first sentence. So the system only shouts the essentials: "SOS! Badly hurt, needs medicine, here are my map coordinates" or "this ration card was reported stolen." Anything bigger (photos, full records) moves by barcode or by the Wi-Fi bubble around the HQ laptop.

When someone shouts, every phone that hears it repeats it once, like people passing a message down a line of hands. A hop-counter stamped on the message dies after five passes so it doesn't echo forever, and a shortlist memory stops the same message being repeated twice.

To save battery, phones don't listen all the time. They listen hard during emergencies, briskly just after meeting a new neighbor, and lazily nap otherwise. Only one message gets shouted at a time, taking turns from a small queue: and an active SOS always jumps the line.

Honest downsides: the shouts aren't secret (anyone with a laptop could eavesdrop) and aren't signed (a prankster could shout a fake). For version 1 inside a closed relief camp that's accepted and written down; locking the messages is the next upgrade.
