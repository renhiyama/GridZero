# GridZero: Feasibility & Viability

Version: 1.0 · Status: Draft · Pure prose

---

## 1. Technical Feasibility: *can it be built and does it work?*

**Proven feasible.** The system exists as a working Flutter codebase with unit and widget test coverage across all core logic.

- **BLE advertisement flooding** is an established technique (Apple Find My, Google Fast Pair, contact-tracing apps all ride advertisements). No exotic hardware: any Android 8+ phone and any Linux laptop with Bluetooth 4.2 suffices.
- **22-byte frames** fit comfortably inside the 31-byte legacy advertising budget with standard overhead: verified by the wire-format math in `BLE_MESH_STACK.md`.
- **Offline crypto** (hash chains, ECDSA, HMAC) is pure software; no hardware security module or cloud key service required.
- **On-device face matching** runs on commodity phones via a small (~5 MB) model; no server inference needed.
- **Wi-Fi hotspot sync** uses standard OS networking APIs; no root beyond one-time sudo setup on the HQ laptop.

**Remaining technical risks:** radio congestion at very high device density; BLE stack quirks across phone vendors (mitigated by duty-cycling and tested adapters); GPS-less positioning accuracy degrades with few neighbors.

## 2. Operational Feasibility: *will people be able to use it?*

- **Citizens need one tap:** SOS is a big button with severity slider. The rotating QR is shown automatically. No typing required.
- **Officers need minimal training:** scan → confirm → done; the flow mirrors familiar payment-QR habits.
- **HQ needs modest IT skill:** Linux laptop, Bluetooth on, one sudo setup for hosting the sync bubble. Setup hints are surfaced inside the app.
- **Graceful degradation everywhere:** no camera → manual payload entry; no GPS → peer-estimated position with honest labelling; no notifications → in-app banner. The system never hard-fails because one sensor is missing.
- **Battery realism:** duty-cycle governor targets under roughly 8% per day for idle citizens; officers scanning actively will drain faster but can top up from camp generators/power banks: no different from any phone-based workflow.

## 3. Economic Viability: *what does it cost?*

| Item | Cost |
|---|---|
| Software | Open-source stack end-to-end (Flutter, BlueZ, SQLite, OSM tiles cached offline); zero licence fees |
| Hardware | HQ: existing Linux laptop. Officers/citizens: phones they already own |
| Connectivity | Zero: no SIMs, no satellite, no airtime |
| Deployment | Side-load APK + copy app bundle to HQ laptop; no app-store dependency (important when stores are unreachable) |

Total marginal cost per camp ≈ **zero**. This beats satellite terminals, mesh-router deployments, and radio-network alternatives by orders of magnitude.

## 4. Legal & Ethical Viability

- Biometric data never leaves the device unless explicitly synced during a physical link exchange; no cloud processing sidesteps most data-localisation issues.
- Passwords/PINs stored hashed, though static-salt hashing and plaintext officer keys are documented debt items on the hardening roadmap.
- The passwordless admin model presumes physical custody of the HQ machine: operationally reasonable in a military/NGO command tent, and stated openly rather than hidden.
- Revocation abuse (anyone can broadcast one over the mesh) is mitigated by requiring in-person verification at claim time.

## 5. Timeline & Maturity Assessment

| Capability | Status |
|---|---|
| Mesh codec, flooding, dedup | Working, unit-tested |
| Ledger append/merge/tamper rejection | Working, unit-tested |
| TOTP claims + PIN fallback | Working, unit-tested |
| Provisioning envelopes | Working, unit-tested |
| SOS lifecycle + respond-ack | Working, integration-tested |
| Wi-Fi bulk sync (both topologies) | Working, desktop-tested |
| Face enrollment | Working, mobile-only |
| Wire-level encryption & frame authentication | **Not started** (roadmap) |
| Multi-day large-camp field validation | **Not yet performed** |

## 6. Comparative Alternatives

| Alternative | Why GridZero wins / loses |
|---|---|
| Satellite internet terminals | High cost, logistics, power; GridZero free but shorter range |
| Dedicated mesh radios (LoRa etc.) | Extra hardware to ship; GridZero uses phones already in victims' pockets |
| Paper ration lists | Free but forgeable, losable, unauditable; GridZero adds tamper-evidence at zero material cost |
| Cloud-based relief apps | Useless without connectivity: the exact condition they're needed in |

## 7. Verdict

Feasible today with commodity hardware, viable at near-zero marginal cost, honest about its security gaps, and ready for pilot deployment at single-camp scale. The gap between "working prototype" and "field-hardened v2" is dominated by wire-level cryptography and multi-day endurance testing: both engineering work, not research problems.

---

## Layman Terms

**Can we actually build this?** Already built: it runs, and the important parts have automated tests proving they behave.

**Will ordinary people manage?** Yes. A scared person presses one button. An aid worker scans a barcode like paying at a shop. The control desk needs one laptop and one techie for setup. If a phone lacks GPS or a good camera, the app quietly works around it instead of breaking.

**Will it cost money?** Almost nothing. No servers, no SIM cards, no licences. It uses the phones people already carry and a laptop someone already owns. Compare that to shipping satellite dishes into a flood zone.

**Is it legal/safe for people's data?** Face scans stay on the person's own phone unless deliberately copied during a cable-free exchange. There are honest weak spots (some keys aren't locked away yet), and they're written down rather than covered up.

**What's left before real-world use?** Two things: scramble the radio messages so eavesdroppers can't read them, and run a multi-day trial with hundreds of phones to shake out real-world radio weirdness. Both are straightforward engineering, not inventions.
