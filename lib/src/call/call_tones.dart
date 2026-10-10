import 'package:audioplayers/audioplayers.dart';
import 'package:riverpod/riverpod.dart';

/// Playback seam for call tones.
///
/// Production uses [AudioCallTones] (audioplayers, asset WAVs). Tests
/// override [callTonesProvider] with [_SilentTones]-like fakes: the
/// audioplayers constructor touches a platform channel, whose async init
/// throws MissingPluginException headless — an unhandled async error that
/// no try/catch at the call site can swallow. Never construct AudioPlayer
/// inside engine code directly.
///
/// Asset paths are relative to the `assets/` prefix (AudioCache default):
/// pass 'call/ringback.wav', never 'assets/call/...' — the latter resolves
/// to assets/assets/... and fails silently inside the try/catch.
abstract class CallTones {
  Future<void> startRingback();
  Future<void> stopRingback();
  void endBlip();
}

class AudioCallTones implements CallTones {
  AudioPlayer? _ring;

  @override
  Future<void> startRingback() async {
    try {
      await _ring?.stop();
      await _ring?.dispose();
      final p = AudioPlayer();
      _ring = p;
      await p.setReleaseMode(ReleaseMode.loop);
      await p.play(AssetSource('call/ringback.wav'));
    } catch (_) {
      _ring = null;
    }
  }

  @override
  Future<void> stopRingback() async {
    final p = _ring;
    _ring = null;
    try {
      await p?.stop();
      await p?.dispose();
    } catch (_) {}
  }

  @override
  void endBlip() {
    try {
      final p = AudioPlayer();
      p.play(AssetSource('call/end.wav')).then((_) {
        p.onPlayerComplete.first.then((_) async {
          try {
            await p.dispose();
          } catch (_) {}
        });
      }, onError: (_) {});
    } catch (_) {}
  }
}

class SilentCallTones implements CallTones {
  @override
  Future<void> startRingback() async {}

  @override
  Future<void> stopRingback() async {}

  @override
  void endBlip() {}
}

final callTonesProvider = Provider<CallTones>((ref) => AudioCallTones());
