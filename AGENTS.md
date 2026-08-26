# AGENTS.md — Caveman Rules for Coding Agents
Agent work here. Follow tribe rules. No break cave.
---

## 1. Golden Rule

* **Make code work. Make code simple.**
* **No fancy talk. No fake magic.**
* **Leave cave cleaner than find.**

---

## 2. Before Say "Done"

* Run build.
* Run tests.
* Run linter.
* **All must pass.** Red light = bad. Green light = good.

## 2b. Both Sides Rule

* Any feature touching admin (HQ laptop) AND client (phone) sides: **update both ends** in the same change — UI copy, flows, and fallback paths on each side that the feature touches.
* When adding a new mechanism (e.g. BLE announce replacing QR), actively remove/deprecate the old UI it replaces on the other side, or say why it stays.
* Check `lib/ui/register_screen.dart` + `lib/ui/officer_screen.dart` + `lib/ui/directory_screen.dart` (admin) against `lib/ui/officer_screen.dart` + `lib/ui/citizen_screen.dart` + `lib/ui/login_screen.dart` (client) before calling it done.

---

## 3. Forbidden Things (Bad! No do!)

* **No leak secrets:** No API keys, passwords, or tokens in code or commits.
* **No fat bloat:** Do not bring big heavy library to do tiny 5-line job.
* **No hide errors:** No empty `catch`, no blind `unwrap`, no swallow crashes.
* **No touch trash:** Never edit `dist/`, `target/`, `node_modules/`, or lockfiles by hand.

---

## 4. Ask Human Chief First

* Breaking database or file format? **Ask first.**
* Deleting files or changing public API? **Ask first.**
* Adding giant system dependency? **Ask first.**

---

## 5. Words and Code Style

* **No buzzwords:** "blazingly fast", "next-gen", "robust" = banned.
* **No emoji soup:** 🚀, ✨, 🔥, 💡 = banned.
* **No robot chatter:** Do not say "Sure, I can help with that!" Just write code.
* **Comments:** Explain *WHY* strange thing exists, not *WHAT* code already shows.
* **No fake papers:** No `PRD_v2_FINAL.md`. Only real technical docs.

---

## 6. Git Rules

* Write clean commit: `subsystem: what change`
* Explain *why* in commit body.
* Bad commits: "fixed bug", "update code" = banned.
