/// HQ directory pages: every identity this laptop has issued or adopted.
///
/// USERS lists the local account store (roles, ids: never password hashes);
/// OFFICERS joins that store with the tamper-evident ledger registry so the
/// admin can see who signs relief records and how they were enlisted. Each
/// row carries re-login QR, demote (officers) and delete actions; a search
/// box filters both pages.
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/ledger/ledger_store.dart';
import 'hud_theme.dart';

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    return SafeArea(
      child: AnimatedBuilder(
        animation: app,
        builder: (context, _) => FutureBuilder<List<Account>>(
          future: app.accounts(),
          builder: (context, snapshot) {
            final all = snapshot.data ?? const <Account>[];
            final users = all
                .where((u) => u.username.contains(_query.toUpperCase()))
                .toList();
            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                Text(
                  '▚▞ USER DIRECTORY',
                  style: TextStyle(
                    color: p.primary,
                    fontFamily: 'monospace',
                    fontSize: 16,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _DirectorySearch(
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'LOCAL ACCOUNTS (${users.length})',
                  child: users.isEmpty
                      ? const HduReadout(
                          'EMPTY',
                          'no accounts match: issue one from REGISTER',
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final u in users)
                              _UserRow(account: u),
                            const SizedBox(height: 6),
                            const HduReadout(
                              'NOTE',
                              'credentials never shown: the re-login QR '
                              'carries them, scan-target only',
                            ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({required this.account});

  final Account account;

  Future<void> _confirmAction(
    BuildContext context, {
    required String title,
    required String body,
    required Color color,
    required Future<void> Function() run,
  }) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.of(ctx).bg,
        title: Text(title, style: TextStyle(color: color)),
        content: Text(body, style: const TextStyle(fontFamily: 'monospace')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: color),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('CONFIRM'),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    await run();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$title · ${account.username}')),
    );
  }

  void _showQr(BuildContext context, AppState app) async {
    final payload = await app.accountProvisionPayload(account.username);
    if (!context.mounted) return;
    if (payload == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('no stored credentials for ${account.username}')),
      );
      return;
    }
    await showReLoginQrDialog(context, payload, account.username);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    final isOfficer = account.role == Role.officer;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(
                color: isOfficer ? p.primary : p.textDim,
              ),
            ),
            child: Text(
              account.role.name.toUpperCase(),
              style: TextStyle(
                color: isOfficer ? p.primary : p.textDim,
                fontFamily: 'monospace',
                fontSize: 9,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.username,
                  style: TextStyle(
                    color: p.text,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
                if (account.officerId != null)
                  Text(
                    account.officerId!,
                    style: TextStyle(
                      color: p.primary,
                      fontFamily: 'monospace',
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'RE-LOGIN QR',
            icon: Icon(Icons.qr_code_2, size: 20, color: p.textDim),
            onPressed: () => _showQr(context, app),
          ),
          if (isOfficer)
            IconButton(
              tooltip: 'DEMOTE TO CITIZEN',
              icon: Icon(Icons.person_remove_outlined, size: 20, color: p.textDim),
              onPressed: () => _confirmAction(
                context,
                title: 'DEMOTE TO CITIZEN?',
                body:
                    '${account.username} loses the officer role and signing '
                    'identity. Ledger history stays intact.',
                color: Colors.orangeAccent,
                run: () async => app.demoteToCitizen(account.username),
              ),
            ),
          IconButton(
            tooltip: 'DELETE ACCOUNT',
            icon: Icon(Icons.delete_outline, size: 20, color: p.error),
            onPressed: () => _confirmAction(
              context,
              title: 'DELETE ACCOUNT?',
              body:
                  '${account.username} is removed from THIS device only. '
                  'Mesh peers and past ledger records are untouched.',
              color: p.error,
              run: () async => app.deleteAccount(account.username),
            ),
          ),
        ],
      ),
    );
  }
}

class OfficersScreen extends StatefulWidget {
  const OfficersScreen({super.key});

  @override
  State<OfficersScreen> createState() => _OfficersScreenState();
}

class _OfficersScreenState extends State<OfficersScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    return SafeArea(
      child: AnimatedBuilder(
        animation: app,
        builder: (context, _) => FutureBuilder<List<OfficerRecord>>(
          future: app.ledger.officers(),
          builder: (context, registrySnapshot) {
            return FutureBuilder<List<Account>>(
              future: app.accounts(),
              builder: (context, accountsSnapshot) {
                final registryAll =
                    registrySnapshot.data ?? const <OfficerRecord>[];
                final byOfficerId = {
                  for (final a
                      in accountsSnapshot.data ?? const <Account>[])
                    if (a.officerId != null) a.officerId!: a,
                };
                final registry = registryAll.where((o) {
                  final linked = byOfficerId[o.officerId]?.username ?? '';
                  return o.officerId.contains(_query.toUpperCase()) ||
                      linked.contains(_query.toUpperCase());
                }).toList();
                return ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  children: [
                    Text(
                      '▚▞ OFFICER DIRECTORY',
                      style: TextStyle(
                        color: p.primary,
                        fontFamily: 'monospace',
                        fontSize: 16,
                        letterSpacing: 3,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _DirectorySearch(
                      onChanged: (v) => setState(() => _query = v.trim()),
                    ),
                    const SizedBox(height: 12),
                    HudPanel(
                      title: 'LEDGER REGISTRY (${registry.length})',
                      child: registry.isEmpty
                          ? const HduReadout(
                              'EMPTY',
                              'no enlistments recorded in the chain yet',
                            )
                          : Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.stretch,
                              children: [
                                for (final o in registry)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${o.officerId}'
                                                '${byOfficerId.containsKey(o.officerId) ? ' · ${byOfficerId[o.officerId]!.username}' : ''}',
                                                style: TextStyle(
                                                  color: p.primary,
                                                  fontFamily: 'monospace',
                                                  fontSize: 12,
                                                  fontWeight:
                                                      FontWeight.bold,
                                                ),
                                              ),
                                              Text(
                                                'via ${o.registeredBy ?? '?'} · '
                                                'key …${o.publicKey.substring(
                                                      o.publicKey.length -
                                                          8,
                                                    )}',
                                                style: TextStyle(
                                                  color: p.textDim,
                                                  fontFamily: 'monospace',
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (byOfficerId
                                            .containsKey(o.officerId))
                                          IconButton(
                                            tooltip: 'RE-LOGIN QR',
                                            icon: Icon(
                                              Icons.qr_code_2,
                                              size: 20,
                                              color: p.textDim,
                                            ),
                                            onPressed: () =>
                                                _officerQr(context, app,
                                                    byOfficerId[o.officerId]!),
                                          ),
                                      ],
                                    ),
                                  ),
                                const SizedBox(height: 6),
                                const HduReadout(
                                  'NOTE',
                                  'the chain is append-only: demoted or '
                                  'deleted officers still appear here',
                                ),
                              ],
                            ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _officerQr(
    BuildContext context,
    AppState app,
    Account account,
  ) async {
    final payload = await app.accountProvisionPayload(account.username);
    if (!context.mounted) return;
    if (payload == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${account.username} no longer holds credentials'),
        ),
      );
      return;
    }
    await showReLoginQrDialog(context, payload, account.username);
  }
}

/// Monospace filter box shared by both directory pages.
class _DirectorySearch extends StatelessWidget {
  const _DirectorySearch({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return TextField(
      autocorrect: false,
      enableSuggestions: false,
      onChanged: onChanged,
      style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: p.text),
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.search, size: 18, color: p.textDim),
        hintText: 'FILTER BY NAME OR ID',
        hintStyle: TextStyle(
          color: p.textDim,
          fontFamily: 'monospace',
          fontSize: 11,
        ),
        isDense: true,
        border: const UnderlineInputBorder(),
      ),
    );
  }
}

/// Re-login QR popup. Deliberately a plain [Dialog], not AlertDialog:
/// AlertDialog measures its content with intrinsic dimensions and
/// QrImageView contains a LayoutBuilder, which cannot serve intrinsics: /// the dialog then builds empty with a rendering-assertion cascade.
Future<void> showReLoginQrDialog(
  BuildContext context,
  String payload,
  String username,
) {
  final p = AppPalette.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppPalette.of(ctx).bg,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'RE-LOGIN QR · $username',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p.primary,
                fontFamily: 'monospace',
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 10),
            HudPagedQr(payload: payload),
            const SizedBox(height: 6),
            HduReadout('REQ', 'phone / login / SCAN PROVISIONING QR'),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('CLOSE'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
