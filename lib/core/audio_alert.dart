/// Response-alert audio: plays the bundled siren/ack tones at the user's
/// configured volume, always through the phone's own speaker so a responder
/// in a noisy field hears it even with a headset plugged in.
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AudioAlert {
  AudioAlert._();

  static final AudioPlayer _player = AudioPlayer();

  static const MethodChannel _channel = MethodChannel('gridzero/audio');

  static bool _speakerForced = false;

  /// Best-effort: Android routes to the built-in speaker via
  /// AudioManager.setSpeakerphoneOn. iOS has no equivalent and the call
  /// simply no-ops (missing plugin): playback still happens at the volume
  /// set below.
  static Future<void> _forceSpeaker() async {
    if (_speakerForced) return;
    try {
      await _channel.invokeMethod('forceSpeakerphone');
      _speakerForced = true;
    } catch (_) {
      // no native backend (desktop / iOS): nothing to force
    }
  }

  static Future<void> _play(String asset, double volume) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _forceSpeaker();
    }
    await _player.setPlayerMode(PlayerMode.lowLatency);
    await _player.setVolume(volume.clamp(0.0, 1.0));
    await _player.stop();
    await _player.play(AssetSource('sounds/$asset'));
  }

  /// Siren loop played on the SOS target's phone when a responder acks.
  static Future<void> playAlert(double volume) => _play('alert.wav', volume);

  /// Short beep on the responder's phone confirming the ack went out.
  static Future<void> playAck(double volume) => _play('ack.wav', volume);
}