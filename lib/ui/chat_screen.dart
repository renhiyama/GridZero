/// Mesh broadcast channel: a slow, shared bulletin board for the local
/// mesh. Short text messages from nearby devices, plus verified official
/// landmark announcements pinned above the conversation.
///
/// Deliberately NOT a realtime messenger: airtime is the scarce resource,
/// so sends are length-capped and cooldown-limited.
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/chat_codec.dart';
import 'hud_theme.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  int _cooldownLeft = 0;
  bool _sending = false;
  int _seenCount = 0;

  @override
  void initState() {
    super.initState();
    // Chat is in the foreground: keep the radio from napping so multi-frame
    // messages are actually heard by sleepy receivers.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => AppScope.of(context).boostRadioForChat(),
    );
  }

  void _maybeScrollToBottom(int count) {
    if (count == _seenCount) return;
    _seenCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final app = AppScope.of(context);
    app.boostRadioForChat();
    setState(() => _sending = true);
    final error = await app.sendBroadcastMessage(_composer.text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (error == null) _composer.clear();
    });
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppPalette.of(context).error,
          content: Text(error, style: const TextStyle(fontFamily: 'monospace')),
        ),
      );
      return;
    }
    // Drive the visible cooldown countdown.
    for (var left = AppState.kChatCooldownS; left > 0; left--) {
      if (!mounted) return;
      setState(() => _cooldownLeft = left);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (mounted) setState(() => _cooldownLeft = 0);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    return SafeArea(
      child: AnimatedBuilder(
        animation: app,
        builder: (context, _) {
          final landmarks = app.officialLandmarks
              .where((l) => !l.isExpired)
              .toList()
            ..sort((a, b) => a.expiresAt.compareTo(b.expiresAt));
          final messages = app.chatMessages;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '\u259A\u259E MESH CHANNEL',
                    style: TextStyle(
                      color: p.primary,
                      fontFamily: 'monospace',
                      fontSize: 16,
                      letterSpacing: 3,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Builder(builder: (context) {
                  _maybeScrollToBottom(messages.length);
                  return ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    children: [
                    // Verified landmarks pinned above the conversation.
                    if (landmarks.isNotEmpty) ...[
                      HudPanel(
                        title: 'OFFICIAL LOCATIONS',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final l in landmarks)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: [
                                    Icon(Icons.verified_user,
                                        size: 14, color: p.primary),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '${l.typeLabel} · ${l.label}',
                                        style: TextStyle(
                                          color: p.primary,
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${l.latitude.toStringAsFixed(3)}, '
                                      '${l.longitude.toStringAsFixed(3)}',
                                      style: TextStyle(
                                        color: p.textDim,
                                        fontFamily: 'monospace',
                                        fontSize: 9,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            HduReadout(
                              'TRUST',
                              'officer-signed · expired entries auto-drop',
                              color: p.textDim,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (messages.isEmpty && landmarks.isEmpty)
                      HudPanel(
                        title: 'QUIET OUT THERE',
                        child: const HduReadout(
                          'CHANNEL',
                          'no messages yet — anything you send repeats to '
                          'nearby devices through the mesh',
                        ),
                      )
                    else
                      ...messages.map(_bubble),
                  ],
                  );
                }),
              ),
              // Composer
              Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: p.primaryDim)),
                  color: p.bg,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _composer,
                        maxLength: 249,
                        onChanged: (_) => setState(() {}),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: p.text,
                        ),
                        decoration: InputDecoration(
                          hintText: 'broadcast to nearby devices…',
                          hintStyle: TextStyle(
                            color: p.textDim,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                          counterText: '',
                          isDense: true,
                          border: const UnderlineInputBorder(),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: (_cooldownLeft > 0 || _sending)
                          ? null
                          : () {
                              if (_composer.text.trim().isEmpty) return;
                              _send();
                            },
                      icon: Icon(
                        Icons.send,
                        color: (_cooldownLeft > 0 || _sending)
                            ? p.textDim
                            : p.primary,
                      ),
                    ),
                  ],
                ),
              ),
              Builder(builder: (context) {
                final wl = wireLengthFor(_composer.text.trim());
                final hint = _composer.text.trim().isEmpty
                    ? 'mesh broadcast · ${AppState.kChatMaxUtf8Bytes}B wire · ${AppState.kChatCooldownS}s cooldown · 220 ASCII chars (249 packed English) or ~70 Hindi/emoji'
                    : 'on wire ${wl ?? 0}/220B · ${AppState.kChatCooldownS}s cooldown';
                return Text(
                  _cooldownLeft > 0 ? 'AIRTIME COOLDOWN · ${_cooldownLeft}s' : hint,
                  style: TextStyle(
                    color: p.textDim,
                    fontFamily: 'monospace',
                    fontSize: 9,
                  ),
                );
              }),
              const SizedBox(height: 6),
            ],
          );
        },
      ),
    );
  }

  Widget _bubble(MeshChatMessage m) {
    final p = AppPalette.of(context);
    final mine = m.senderName == AppScope.of(context).username;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.all(8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: mine ? p.primary : p.primaryDim),
          color: mine ? p.primary.withValues(alpha: 0.08) : p.panel,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${m.senderName} · ${m.at.hour.toString().padLeft(2, '0')}:'
              '${m.at.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                color: p.textDim,
                fontFamily: 'monospace',
                fontSize: 9,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              m.text,
              style: TextStyle(
                color: p.text,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
