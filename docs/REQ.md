GridZero — Unified Product Requirements Document (PRD) & Software Requirements Specification (SRS)

Project Name: GridZero (ResQMesh / RahatMesh)

System Type: Air-Gapped Disaster Relief & Peer-to-Peer Triage System

Target Environment: Android / Linux Field Terminals (Zero Internet, Zero Cellular) & Web Command Visualizer

Document Version: 1.1.0

Status: Approved Multi-Platform Architecture Base

Part 1: Product Requirements Document (PRD)

1. Executive Summary & Vision

During major disasters (floods, earthquakes, grid failures), cellular towers and power infrastructure fail rapidly. Emergency response is crippled by two bottlenecks:

Communication Blackouts: Trapped citizens and field teams cannot communicate due to total infrastructure failure.

Relief Supply Fraud & Chaos: Ration distribution centers lack real-time or offline verification, leading to double-dipping, hoarded supplies, and unverified aid claims.

GridZero bridges these gaps by combining a peer-to-peer Bluetooth Low Energy (BLE) mesh network with offline cryptographic dynamic QR verification, packaged inside a single adaptive Flutter codebase. It operates entirely air-gapped on standard consumer smartphones and ruggedized field tablets, while compiling seamlessly to a Web Command HQ Dashboard for real-time triage visualizer and judge demonstrations.

2. User Personas & Scenarios

Persona A: Citizen / Survivor (Ramesh)

Context: Trapped in a flood zone with no cellular network or internet connection.

Goal: Broadcast an SOS triage beacon (medical, food, water needs) and securely claim daily ration allocations at a local relief camp without needing an active data connection.

Key Interaction: Opens GridZero in default Citizen Mode, sets emergency status, broadcasts BLE beacon, and presents a dynamic offline QR code at relief distribution points.

Persona B: Field Relief Officer / NDRF Responder (Priya)

Context: Operating at a local aid hub or patrolling disaster sectors with a mobile terminal.

Goal: Detect nearby survivor SOS signals on an offline vector map, verify citizen ration tokens without double-claim fraud, and sync offline ledger updates across peer responder devices over BLE.

Key Interaction: Unlocks Officer Mode via offline QR key enlistment, scans citizen dynamic QR codes, logs ration dispatches into a local append-only hash ledger, and views live BLE beacon positions on a tactical HUD map.

Persona C: Disaster Command HQ Coordinator / Hackathon Judge (Director Roy)

Context: Stationed at a command center or viewing a project demonstration on a desktop web browser.

Goal: Observe aggregated mesh state updates, triage heatmaps, supply depletion metrics, and ledger logs on a high-density dashboard.

Key Interaction: Views the Web Command HQ Visualizer, switching between a live gateway bridge and a built-in P2P mesh simulator.

3. Unified Delivery & Deployment Architecture

┌─────────────────────────────────────────────────────────────────────────────┐
│                       GridZero Single Unified Codebase                     │
│                                 (lib/main.dart)                             │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
            ┌──────────────────────────┼──────────────────────────┐
            ▼                          ▼                          ▼
  [ Target: Mobile/Desktop ] [ Target: Mobile/Desktop ]     [ Target: Web Target ]
     Citizen Mode (Default)   Officer Mode (Enlisted)     Command HQ Visualizer
  ┌────────────────────────┐ ┌────────────────────────┐ ┌────────────────────────┐
  │ • One-Tap SOS Broadcast│ │ • Offline QR Scanner   │ │ • Triage Heatmap HUD   │
  │ • Dynamic Dynamic QR   │ │ • Hash Ledger Check    │ │ • Live Mesh Telemetry  │
  │ • Background BLE Relay │ │ • Tactical Vector Map  │ │ • P2P Mesh Simulator   │
  └────────────────────────┘ └────────────────────────┘ └────────────────────────┘


4. Core Functional Feature Matrix

Module

Feature ID

Feature Description

Target Platforms

Priority

Mesh Core

FEAT-MESH-01

P2P BLE Advertising & Scanning for offline node discovery

Android / Linux

P0 (Critical)

Mesh Core

FEAT-MESH-02

Multi-hop packet relay (flooding algorithm with TTL and deduplication)

Android / Linux

P0 (Critical)

Triage / SOS

FEAT-SOS-01

One-tap emergency beacon broadcast with severity & coordinates

Mobile / Linux

P0 (Critical)

Relief Ledger

FEAT-LEDG-01

Dynamic TOTP-HMAC QR token generation for offline ration claims

All Targets

P0 (Critical)

Relief Ledger

FEAT-LEDG-02

Offline QR scanning & double-claim prevention via local SQLite hash chain

Android / Linux

P0 (Critical)

Enlistment

FEAT-ROLE-01

Cryptographic Air-Gapped Officer Role Activation via Master Key QR

All Targets

P1 (High)

Tactical UI

FEAT-UI-01

OLED Cyber-Industrial HUD with 1px structural borders & glowing halos

All Targets

P1 (High)

Command Visual

FEAT-DASH-01

Web Command HQ Dashboard with live telemetry & mesh simulator

Web / Desktop

P1 (High)

Tactical Map

FEAT-MAP-01

Offline MBTiles/Vector map rendering with live BLE node overlays

Android / Linux

P1 (High)

Part 2: Software Requirements Specification (SRS)

1. Functional Requirements (FR)

FR-1: BLE Mesh Networking & Protocol Rules

FR-1.1: Mobile and desktop terminals MUST run concurrent BLE Peripheral (advertising) and Central (scanning) modes.

FR-1.2: Packets MUST be strictly bounded to a 22-byte binary payload to fit within legacy BLE Advertising Data frames ($31\text{ bytes}$ max limit minus flags and headers).

FR-1.3: Every packet MUST contain a 1-byte Time-To-Live (TTL) counter initialized to $N=5$. Each relay hop MUST decrement TTL by 1. Packets with $\text{TTL} = 0$ MUST be dropped.

FR-1.4: Nodes MUST maintain a local sliding-window Bloom filter or LRU cache storing the last 500 seen packet nonces to eliminate packet looping.

FR-2: Air-Gapped Cryptographic Enlistment & Dynamic QR Verification

FR-2.1: Citizen dynamic QR codes MUST embed a Time-Based One-Time Password (TOTP) constructed via HMAC-SHA256:

$$\text{Token} = \text{HMAC-SHA256}(K_{\text{citizen}}, T_{\text{window}} \parallel \text{CitizenID})$$

where $T_{\text{window}} = \lfloor \text{EpochSeconds} / 30 \rfloor$.

FR-2.2: Tokens MUST auto-refresh every 30 seconds to prevent dynamic screenshot duplication or static printout fraud.

FR-2.3: Officer Mode activation MUST NOT require an active internet connection. Swapping from Citizen to Officer state MUST validate a scanned Master Key QR signature against an embedded public key (officer_pubkey.pem).

FR-3: Local Append-Only Hash-Chain Ledger

FR-3.1: Local ledger records MUST be stored in an embedded SQLite database using Drift or standard SQLite.

FR-3.2: Every transaction record MUST contain: [RecordID, CitizenID, ItemType, Timestamp, OfficerID, PrevHash, CurrentHash].

FR-3.3: The CurrentHash MUST be calculated as:

$$\text{CurrentHash} = \text{SHA256}(\text{RecordData} \parallel \text{PrevHash})$$

FR-3.4: Duplicate claims within a 24-hour window MUST trigger a local database constraint violation and raise an anti-fraud HUD alert.

FR-3.5: Local ledger records MUST propagate to other terminals (HQ aggregation) over the BLE mesh via compact single-frame record packets and pull requests; receivers MUST absorb records into an aggregated sync table without rewriting the sender's hash chain, rejecting exact duplicates and cross-officer daily double-claims.

FR-3.6: Every terminal MUST announce its account identity (username + role) over the mesh so peer lists and HQ dashboards show names rather than bare node ids.

FR-3.7: Officer and HQ terminals MUST be able to flag a citizen card as stolen or suspended by diffusing a revocation alert (0x06) over the mesh; every claim point MUST refuse flagged cards until a CLEARED alert lifts the flag, and the revocation set MUST persist across restarts.

FR-3.8: Every officer-issued ledger claim MUST be signed with a deterministic ECDSA-P256 key (RFC-6979) unique to the issuing device; HQ MUST verify the signature against the issuer's embedded public key and surface tampered blocks as SIG✗.

FR-3.9: A terminal MAY adopt a locally unknown account for cross-device login by probing the mesh (0x08), reassembling the credential chunks announced by an adjacent device (0x07), and adopting the account only when the full password hash matches the typed password. ADMIN accounts MUST NOT be announced or adopted over the mesh.

FR-3.10: Claims MAY be fractional (0.25–1.0 ration units per person) and MAY carry a familyId. When a claim carries a familyId, the claim point MUST honor a signed Tier-2 family ration card (canonical payload signed by the HQ key) and refuse the claim when the family card is unknown, the claimant is not a listed member, or the household's cumulative units for the UTC day would exceed the card's daily entitlement.

FR-3.11: Citizens MAY register a 4–6 digit knowledge PIN alongside their account. When the TOTP window is stale or forged, the officer terminal MUST offer a PIN fallback: the claim succeeds only if the SHA-256 hash of the presented PIN matches the PIN hash embedded in the citizen's QR payload; otherwise the claim is rejected as a PIN mismatch.

FR-3.12: In-app packet and ledger rendering MUST use tactical bracket symbols so operators can read a feed at a glance: SOS beacons as `[▲ SOS]`, ledger records as `[≡ LEDGER]`, revocation alerts as `[✕ REVOKED]`, identity announcements as `[▸ ID]`, account records as `[▸ ACC]`, and signature status as `[SIG✓]`/`[SIG✗]`/`[SIG·]`. Claims display their unit amount (e.g. `0.75U`) and ledger rows carry the familyId when present.

FR-4: Web Command HQ & Mesh Simulation (Judge Visualizer)

FR-4.1: The Web target MUST render a top-level Command HQ dashboard displaying live aggregate mesh health, active SOS beacons, and supply allocation logs.

FR-4.2: The Web interface MUST include a Mesh Simulator Mode capable of generating 20–50 virtual nodes with moving spatial coordinates, fluctuating RSSI values, and synthetic triage broadcasts for live judge demonstrations.

2. Binary Wire Protocols & Data Schemas

2.1 18-Byte BLE Mesh Packet Format

 0               1               2               3
 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Magic (0xA5) | Packet Type   |   Node ID Suffix (16-bit)     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Latitude (int32)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Longitude (int32)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| Triage Flags  | TTL & Hop     |     Sequence ID (16-bit)      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| CRC-8 / Check | RESERVED      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+


Byte Offsets

Parameter

Data Type

Field Description

Byte 0

MAGIC

uint8

Fixed constant 0xA5 identifying GridZero protocol frames.

Byte 1

TYPE

enum (uint8)

0x01: SOS Beacon, 0x02: Relay Status, 0x03: Ledger Sync Request, 0x04: Identity, 0x05: Ledger Record, 0x06: Revocation Alert, 0x07: Account Record, 0x08: Account Request.

For types 0x04–0x07 the coordinate, triage and altitude bytes are reused as payload (no room in a 22-byte frame): identity carries the ≤12-char username across LAT/LON/ALT with role in TRIAGE and name length in FLAGS; ledger record packs citizen ID and officer ID (hex) into LAT/LON, epoch-seconds claim time into ALT, and the ration item index into TRIAGE.

0x06 (Revocation Alert) — issued by officers/HQ when a citizen card is stolen or suspended; a reason code 2 (CLEARED) unflags it: citizen ID (bit-packed) in LAT, sha256(citizen-id) digest tag in LON, reason (0 stolen / 1 suspended / 2 cleared) in TRIAGE-severity, issuedAt epoch32 in ALT.

0x07 (Account Record) — chunked credential for cross-device login: chunk index in TRIAGE-severity, total chunk count in ALT, and 11 bytes of payload across LAT/LON/ALT. A full credential is `[nameLen][username ≤12][role][sha256('gridzero:pw:<password>') 32B]` split into 5 chunks. A fresh device reassembles chunks from one sender and adopts the account if the hash matches the typed password; ADMIN is never announced.

0x08 (Account Request) — coords-group frame (flags=0, no payload). Broadcast at the login screen to probe neighbouring terminals for their local accounts.

Bytes 2–3

SENDER_ID

uint16

Truncated unique hardware node identifier hash.

Bytes 4–7

LATITUDE

int32

Fixed-point coordinate: $\text{Lat} \times 10^7$ (Accuracy to $\approx 1.1\text{ cm}$).

Bytes 8–11

LONGITUDE

int32

Fixed-point coordinate: $\text{Lon} \times 10^7$.

Byte 12

TRIAGE_FLAGS

uint8

Bitfield: [7: Medical] [6: Trapped] [5: Water] [4: Food] [3..0: Severity 1-5].

Byte 13

TTL_HOP

uint8

[7..4: Initial TTL] [3..0: Current Hop Count].

Bytes 14–15

SEQ_NUM

uint16

Monotonically increasing packet sequence counter for deduplication.

Byte 16

CRC8

uint8

Polynomial checksum ($x^8 + x^2 + x + 1$) across bytes 0–15.

Byte 17

FLAGS

uint8

Bitfield: bit 0 = SOS-cleared marker (deactivated SOS propagation). For 0x05 (Ledger Record) bit 0 is the record marker and bits 1–3 encode the fractional claim as quarter-units (1–8); value 0 is reserved for legacy frames and decodes to a full unit (1.0).

Bytes 18–21

ALTITUDE

int32

Fixed-point altitude in cm above sea level; `0x80000000` = no data.

2.2 SQLite Local Ledger Schema (ledger_db.sql)

CREATE TABLE IF NOT EXISTS ledger_records (
    record_id TEXT PRIMARY KEY,
    citizen_id TEXT NOT NULL,
    ration_code TEXT NOT NULL,
    claimed_at INTEGER NOT NULL,
    officer_id TEXT NOT NULL,
    prev_hash TEXT NOT NULL,
    current_hash TEXT NOT NULL,
    sync_status INTEGER DEFAULT 0, -- 0: Local Only, 1: Mesh Synced, 2: Cloud Synced
    claim_units REAL NOT NULL DEFAULT 1.0, -- fractional ration units (schema v4)
    family_id TEXT -- Tier-2 family ration card (schema v4)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_citizen_daily_claim 
ON ledger_records (citizen_id, ration_code, (claimed_at / 86400));

CREATE TABLE IF NOT EXISTS family_cards (
    family_id TEXT PRIMARY KEY,
    ration_code TEXT NOT NULL,
    daily_units REAL NOT NULL,
    member_ids TEXT NOT NULL -- JSON array of citizen ids
);

CREATE TABLE IF NOT EXISTS known_mesh_nodes (
    node_id INTEGER PRIMARY KEY,
    last_latitude REAL,
    last_longitude REAL,
    triage_severity INTEGER,
    last_seen_epoch INTEGER
);


3. Non-Functional Requirements (NFR)

NFR-1: Battery Efficiency & Thermal Safety

Passive low-power BLE scan duty cycles ($1.1\text{s}$ scan window / $4.9\text{s}$ sleep window) MUST be enforced in background mode.

Background battery consumption MUST NOT exceed $3.5\%$ per hour on mid-tier Android hardware.

NFR-2: Performance & User Experience

Tactical HUD components MUST maintain 60–120 FPS rendering during live RSSI telemetry updates without frame drops.

Dynamic QR token generation and verification latency MUST execute under $200\text{ms}$.

NFR-3: Security & Anti-Fraud

All dynamic QR claims MUST expire after the 30-second TOTP window.

Replay attacks on broadcast BLE frames MUST be rejected using sequence numbers and local sliding-window Bloom filters.

4. Verification & Acceptance Criteria

Air-Gapped Operation: The mobile app MUST complete 100 consecutive ration verification scans and BLE relays while operating in absolute Airplane Mode (WiFi, Cellular, and Cloud disabled).

Duplicate Claim Rejection: Any attempt to claim rations twice for the same citizen ID within 24 hours MUST trigger a local database rejection and anti-fraud UI warning.

Multi-Platform Web Parity: The Web Command HQ Dashboard MUST load seamlessly in modern desktop browsers and render simulated mesh nodes without requiring native BLE hardware.
