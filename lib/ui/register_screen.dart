/// HQ registration page: air-gapped provisioning for the two enrolled roles,
/// kept on separate tabs so citizen and officer onboarding never mix. Officer
/// enrolments also land in the local enrolment directory; at-rest encryption
/// of that directory is a planned follow-up.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/identity.dart';
import '../core/ledger/ledger_store.dart';
import '../core/ledger/officer_sign.dart';
import '../core/mesh_packet.dart';
import '../core/provision_packet.dart';
import 'hud_theme.dart';

class RegisterScreen extends StatelessWidget {
  const RegisterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    return SafeArea(
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Text(
                    '▚▞ REGISTRATION',
                    style: TextStyle(
                      color: p.primary,
                      fontFamily: 'monospace',
                      fontSize: 16,
                      letterSpacing: 3,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: p.primary),
                      color: p.primary.withValues(alpha: 0.12),
                    ),
                    child: Text(
                      'AIR-GAPPED',
                      style: TextStyle(
                        color: p.primary,
                        fontFamily: 'monospace',
                        fontSize: 11,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const TabBar(
              tabs: [
                Tab(text: 'CITIZEN'),
                Tab(text: 'OFFICER'),
              ],
            ),
Expanded(
                child: TabBarView(
                  children: [
                    _RegisterTab(
                      children: [
                        _Accordion(
                          sections: [
                            _AccordionSection(
                              title: 'CREATE CITIZEN ACCOUNT',
                              builder: (_) => _CreateAccountPanel(
                                app: app,
                                role: Role.citizen,
                              ),
                            ),
                            _AccordionSection(
                              title: 'FAMILY CARD QR',
                              builder: (_) => _FamilyCardPanel(app: app),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _FamilyPanel(app: app),
                        const SizedBox(height: 12),
                        _RevocationsPanel(app: app),
                      ],
                    ),
                    _RegisterTab(
                      children: [
                        _Accordion(
                          sections: [
                            _AccordionSection(
                              title: 'ENROL OFFICER (FROM EXISTING USER)',
                              builder: (_) => _CreateAccountPanel(
                                app: app,
                                role: Role.officer,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),
                        _OfficerRegistryPanel(app: app),
                        const SizedBox(height: 12),
                        _EncryptionNote(),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// HQ-issued account enrolment (source of truth). The admin fills the fields
/// (or rolls a random identity), and the phone scans the paged QR to adopt
/// the account: no typing on the citizen's device, no shared secrets over
/// the mesh. The password hash travels in the QR; the plaintext is shown here
/// so the admin can tell the citizen what to type on future logins.
class _CreateAccountPanel extends StatefulWidget {
  const _CreateAccountPanel({required this.app, required this.role});

  final dynamic app;
  final Role role;

  @override
  State<_CreateAccountPanel> createState() => _CreateAccountPanelState();
}

class _CreateAccountPanelState extends State<_CreateAccountPanel> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _pin = TextEditingController();
  final _aadhaar = TextEditingController();
  final _family = TextEditingController();
  String? _payload;
  String? _error;

  bool get _isOfficer => widget.role == Role.officer;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _pin.dispose();
    _aadhaar.dispose();
    _family.dispose();
    super.dispose();
  }

  void _roll() {
    // Officer enrolment targets an EXISTING user, so only the optional
    // password-reset field rolls; the username must be typed/selected.
    final r = Random();
    if (!_isOfficer) {
      _username.text = randomCitizenName(r);
      _aadhaar.text = randomAadhaar(r);
      _family.text = randomRationId(r);
    }
    _password.text = _randomPassword(r);
  }

  static String _randomPassword(Random r) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(8, (_) => alphabet[r.nextInt(alphabet.length)]).join();
  }

  Future<void> _generate() async {
    final name = _username.text.trim().toUpperCase();
    final password = _password.text;
    if (name.isEmpty) return _fail('enter a username');
    if (name.length > 12) return _fail('username must be 12 characters or less');
    if (name == 'ADMIN') return _fail('ADMIN is reserved for HQ');

    // OFFICER: enrol an existing user. The account must already exist: an
    // officer identity is a promotion, never a fresh creation.
    if (_isOfficer) {
      final payload = await widget.app.issueOfficerPromotion(
        name,
        newPassword: password.isEmpty ? null : password,
      );
      if (!mounted) return;
      if (payload.startsWith('ERR:')) return _fail(payload.substring(4));
      setState(() {
        _payload = payload;
        _error = null;
      });
      return;
    }

    if (password.length < 4) return _fail('password must be 4+ characters');
    final pin = _pin.text.trim();
    if (pin.isNotEmpty && !RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      return _fail('PIN must be 4-6 digits');
    }
    final aadhaar = _aadhaar.text.trim().isEmpty
        ? null
        : _aadhaar.text.trim();
    if (aadhaar != null && !aadhaarRe.hasMatch(aadhaar)) {
      return _fail('Aadhaar must be 12 digits, first digit 2-9');
    }
    final family = _family.text.trim().isEmpty ? null : _family.text.trim();
    if (family != null && !rationRe.hasMatch(family.toUpperCase())) {
      return _fail('Ration card id must be 8-16 letters, digits, / or -');
    }
    final passwordHash = sha256
        .convert(utf8.encode('gridzero:pw:$password'))
        .toString();
    final authorityPub = await widget.app.authorityPubKey();
    // Derive the citizen's signing pub and certify it with HQ authority so
    // the QR is self-contained and the citizen's future chat/landmark sigs
    // can be verified without a separate roster lookup.
    final citizenKey = deriveOfficerKey(passwordHash);
    final citizenPubB64 = base64Encode(citizenKey.$1);
    final citizenCert = widget.app.certifyOfficerKey(name, citizenPubB64);
    final netKeyB64 = await widget.app.networkKeyB64();
    final payload = encodeAccountProvision(
      purpose: ProvisionPurpose.citizen,
      username: name,
      passwordHash: passwordHash,
      authorityPub: authorityPub,
      certB64: citizenCert,
      netKeyB64: netKeyB64,
      pinHash: pin.isEmpty
          ? null
          : sha256.convert(utf8.encode('gridzero:pin:$pin')).toString(),
      aadhaar: aadhaar,
      familyId: family?.toUpperCase(),
      signer: (canonical) => base64Encode(signOfficerRecord(widget.app.authorityPrivateForSign!, canonical)),
    );
    // Record the issued account in HQ's local directory immediately: the
    // handoff QR may be lost, but the ledger of issued identities survives.
    final error = await widget.app.saveIssuedAccount(
      username: name,
      passwordHash: passwordHash,
      role: Role.citizen,
      pinHash: pin.isEmpty ? null : sha256.convert(utf8.encode('gridzero:pin:$pin')).toString(),
      aadhaar: aadhaar,
      familyId: family?.toUpperCase(),
    );
    // Stash the cert for this citizen so future re-issues use the same one.
    final prefs = await widget.app.prefsForTest;
    await prefs.setString('cert_sig_$name', citizenCert);
    await prefs.setString('cert_sig_${name}_citizen', citizenCert);
    if (!mounted) return;
    if (error != null) return _fail(error);
    setState(() {
      _payload = payload;
      _error = null;
    });
  }

  void _fail(String message) {
    setState(() {
      _payload = null;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final label = _isOfficer ? 'ENROL OFFICER' : 'CREATE CITIZEN ACCOUNT';
    return HudPanel(
      title: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isOfficer)
            const HduReadout(
              'RULE',
              'officers are promoted from existing users: create the '
              'citizen account first',
            )
          else ...[
            _Field(_password, 'PASSWORD', hint: 'relay to the phone owner'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _Field(_pin, 'PIN (OPTIONAL, 4-6 DIGITS)')),
                const SizedBox(width: 8),
                Expanded(child: _Field(_aadhaar, 'AADHAAR (12 DIGITS)')),
              ],
            ),
            const SizedBox(height: 8),
            _Field(_family, 'RATION CARD (OPTIONAL)'),
            const SizedBox(height: 12),
          ],
          _Field(
            _username,
            _isOfficer ? 'EXISTING USERNAME' : 'USERNAME',
            hint: _isOfficer ? 'user to promote' : '12 chars max',
          ),
          if (_isOfficer) ...[
            const SizedBox(height: 8),
            _Field(_password, 'RESET PASSWORD (OPTIONAL)', hint: 'blank keeps current'),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _roll,
                  child: const Text(
                    'ROLL RANDOM',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: _generate,
                  child: Text(
                    _isOfficer ? 'ENROL + GENERATE QR' : 'GENERATE QR',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(
                color: p.error,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ],
          if (_payload != null) ...[
            const SizedBox(height: 14),
            Center(child: HudPagedQr(payload: _payload!)),
            const SizedBox(height: 6),
            const HduReadout(
              'HOW',
              'Phone / PROVISION ACCOUNT / scan each QR in order.',
            ),
            const SizedBox(height: 8),
            Text(
              _isOfficer
                  ? 'ENROLLED ${_username.text.trim().toUpperCase()} AS OFFICER'
                  : 'HAND TO OWNER: USER ${_username.text.trim().toUpperCase()} · '
                      'PASSWORD ${_password.text}',
              style: TextStyle(
                color: p.primary,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.controller, this.label, {this.hint});

  final TextEditingController controller;
  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return TextField(
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: p.text),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const UnderlineInputBorder(),
        labelStyle: TextStyle(
          color: p.textDim,
          fontFamily: 'monospace',
          fontSize: 10,
        ),
      ),
    );
  }
}

/// Scrollable body for one registration tab, with bottom clearance so the
/// fade-into-nav never covers the last panel.
class _RegisterTab extends StatelessWidget {
  const _RegisterTab({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return HudScroll(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
      children: children,
    );
  }
}

/// Accordion: only one QR-producing panel is visible at a time, so a paged
/// scan can never mix frames from two panels. Offstage keeps the hidden
/// panel's form state alive while it contributes no size to the layout.
class _Accordion extends StatefulWidget {
  const _Accordion({required this.sections});

  final List<_AccordionSection> sections;

  @override
  State<_Accordion> createState() => _AccordionState();
}

class _AccordionSection {
  const _AccordionSection({required this.title, required this.builder});

  final String title;
  final WidgetBuilder builder;
}

class _AccordionState extends State<_Accordion> {
  int _open = 0;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < widget.sections.length; i++)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: _open == i
                    ? p.primary.withValues(alpha: 0.12)
                    : p.panel,
                child: InkWell(
                  onTap: () => setState(() => _open = i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _open == i
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                          color: p.primary,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.sections[i].title,
                            style: TextStyle(
                              color: _open == i ? p.primary : p.text,
                              fontFamily: 'monospace',
                              fontSize: 12,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Offstage(
                offstage: _open != i,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: widget.sections[i].builder(context),
                ),
              ),
            ],
          ),
        const SizedBox(height: 4),
        const HduReadout(
          'SCAN RULE',
          'ONE QR PANEL AT A TIME: scan only the panel you opened.',
        ),
      ],
    );
  }
}

/// HQ issues a household ration card by filling this form; the QR is the
/// trust handoff, so nothing needs signing. Officers scan it to cache the
/// card and unlock fractional claims against the daily entitlement.
class _FamilyCardPanel extends StatefulWidget {
  const _FamilyCardPanel({required this.app});

  final dynamic app;

  @override
  State<_FamilyCardPanel> createState() => _FamilyCardPanelState();
}

class _FamilyCardPanelState extends State<_FamilyCardPanel> {
  final _family = TextEditingController();
  final _members = TextEditingController();
  String _rationCode = 'Rice';
  double _dailyUnits = 4.0;
  String? _payload;
  String? _error;

  static const _items = ['Rice', 'Water', 'Blanket', 'Medicine', 'Fuel'];
  static const _unitOptions = [1.0, 2.0, 4.0, 6.0, 8.0];

  @override
  void dispose() {
    _family.dispose();
    _members.dispose();
    super.dispose();
  }

  void _generate() {
    final familyId = _family.text.trim().toUpperCase();
    if (!rationRe.hasMatch(familyId)) {
      return _fail('family id must be 8-16 letters, digits, / or -');
    }
    final ids = _members.text
        .split(',')
        .map((m) => m.trim().toUpperCase())
        .where((m) => m.isNotEmpty)
        .toList();
    if (ids.isEmpty) return _fail('enter at least one member id');
    if (ids.any((m) => !RegExp(r'^CIT-\d{8}$').hasMatch(m))) {
      return _fail('member ids must look like CIT-XXXXXXXX');
    }
    setState(() {
      _payload = encodeFamilyCardProvision(
        familyId: familyId,
        rationCode: _rationCode,
        dailyUnits: _dailyUnits,
        memberIds: ids,
      );
      _error = null;
    });
  }

  void _fail(String message) {
    setState(() {
      _payload = null;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return HudPanel(
      title: 'ISSUE FAMILY CARD',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Field(_family, 'FAMILY ID', hint: 'e.g. RCB-2026-0041'),
          const SizedBox(height: 8),
          _Field(
            _members,
            'MEMBER CITIZEN IDS',
            hint: 'CIT-XXXXXXXX,CIT-XXXXXXXX',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  value: _rationCode,
                  isExpanded: true,
                  dropdownColor: p.panel,
                  style: TextStyle(
                    color: p.primary,
                    fontFamily: 'monospace',
                  ),
                  items: _items
                      .map(
                        (i) => DropdownMenuItem(value: i, child: Text(i)),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _rationCode = v ?? 'Rice'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<double>(
                  value: _dailyUnits,
                  isExpanded: true,
                  dropdownColor: p.panel,
                  style: TextStyle(
                    color: p.primary,
                    fontFamily: 'monospace',
                  ),
                  items: _unitOptions
                      .map(
                        (u) => DropdownMenuItem(
                          value: u,
                          child: Text('${u.toStringAsFixed(0)}U/DAY'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _dailyUnits = v ?? 4.0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _generate,
            child: const Text(
              'GENERATE QR',
              style: TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(
                color: p.error,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ],
          if (_payload != null) ...[
            const SizedBox(height: 14),
            Center(child: HudPagedQr(payload: _payload!)),
            const SizedBox(height: 6),
            const HduReadout(
              'HOW',
              'Officer app / ENLIST FAMILY CARD / scan each QR in order.',
            ),
          ],
        ],
      ),
    );
  }
}

/// HQ laptop side of the officer DB sync: scan the phone's hotspot QR, join
/// the temporary network, push this laptop's DB clone, then disconnect and
/// restore the previously active connection (wifi or ethernet).
class _OfficerRegistryPanel extends StatelessWidget {
  const _OfficerRegistryPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        return FutureBuilder<List<OfficerRecord>>(
          future: app.ledger.officers(),
          builder: (context, snapshot) {
            final officers = snapshot.data ?? const <OfficerRecord>[];
            return HudPanel(
              title: 'OFFICER REGISTRY',
              child: officers.isEmpty
                  ? const HduReadout(
                      'REGISTERED',
                      'none yet: create an officer account to enlist one',
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final o in officers)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '${o.officerId} · ${o.registeredBy ?? '·'} · '
                              '${_shortKey(o.publicKey)} · '
                              'enlisted ${o.enlistedAt}',
                              style: TextStyle(
                                color: p.primary,
                                fontFamily: 'monospace',
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    ),
            );
          },
        );
      },
    );
  }

  static String _shortKey(String b64) {
    if (b64.length <= 16) return b64;
    return '${b64.substring(0, 8)}…${b64.substring(b64.length - 8)}';
  }
}

/// Explicit marker that the officer directory's at-rest encryption is the
/// planned follow-up, so nobody mistakes plaintext public keys for a secure
/// vault.
class _EncryptionNote extends StatelessWidget {
  const _EncryptionNote();

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return HudPanel(
      title: 'ENCRYPTED OFFICER DB',
      borderColor: p.primaryDim,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'PLANNED: OFFICER IDENTITIES ARE STORED IN CLEAR PUBLIC-KEY '
            'FORM TODAY. THE AT-REST ENCRYPTION LAYER IS A FOLLOW-UP.',
            style: TextStyle(
              color: p.textDim,
              fontFamily: 'monospace',
              fontSize: 10,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Card revocation list: which citizen IDs are blacklisted and why, as
/// relayed by field officers (0x06 frames) and persisted locally. Stolen and
/// suspended cards are refused at every claim point; cleared restores them.
///
/// AnimatedBuilder re-runs the future on every app notify, so a revocation
/// alert arriving over the mesh repaints the panel immediately.
class _RevocationsPanel extends StatelessWidget {
  const _RevocationsPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        return FutureBuilder<List<RevocationEntry>>(
          future: app.ledger.revocations(),
          builder: (context, snapshot) {
            final entries = snapshot.data ?? const <RevocationEntry>[];
            return HudPanel(
              title: 'CARD REVOCATIONS',
              child: entries.isEmpty
                  ? const HduReadout('STATUS', 'no cards flagged')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final e in entries)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              '${e.citizenId} ${revocationReasonLabel(e.reasonCode)} '
                              '· node ${e.sourceNode} · ${e.issuedAt}',
                              style: TextStyle(
                                color: p.primary,
                                fontFamily: 'monospace',
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    ),
            );
          },
        );
      },
    );
  }
}

/// Tier-2 household ration cards on file: entitlement vs. what has already
/// been drawn today, so command sees which families are nearly spent.
class _FamilyPanel extends StatelessWidget {
  const _FamilyPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        return FutureBuilder<List<FamilyCard>>(
          future: app.ledger.familyCards(),
          builder: (context, snapshot) {
            final cards = snapshot.data ?? const <FamilyCard>[];
            return HudPanel(
              title: 'FAMILY RATION CARDS',
              child: cards.isEmpty
                  ? const HduReadout('CARDS', 'no family cards enlisted')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final c in cards)
                          FutureBuilder<double>(
                            future: app.ledger.familyUsedUnits(
                              c.familyId,
                              DateTime.now().toUtc().millisecondsSinceEpoch ~/
                                  1000 ~/
                                  86400 *
                                  86400,
                            ),
                            builder: (context, usedSnap) {
                              final used = usedSnap.data ?? 0.0;
                              final spent = used >= c.dailyUnits;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2,
                                ),
                                child: Text(
                                  '${c.familyId} ${c.rationCode} '
                                  '${used.toStringAsFixed(2)}/${c.dailyUnits.toStringAsFixed(2)}U '
                                  '${spent ? '[SPENT]' : ''} · '
                                  '${c.memberCitizenIds.length} members',
                                  style: TextStyle(
                                    color: spent ? p.error : p.text,
                                    fontFamily: 'monospace',
                                    fontSize: 10,
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
            );
          },
        );
      },
    );
  }
}
