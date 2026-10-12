import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:riverpod/riverpod.dart';

import '../app/providers.dart';
import '../auth/auth_repository.dart';
import 'call_api.dart';
import 'call_diagnostics.dart';
import 'call_tones.dart';
import 'sdp_tuning.dart';
import 'group_call.dart' show groupCallProvider;
import 'media_session.dart';
import 'camera_lock.dart';
import 'quality_tier.dart';
import 'sfu_marker.dart';
enum CallPhase { ringing, active }

/// One live call. Null state = idle.
class ActiveCall {
  ActiveCall({
    required this.callId,
    required this.peerNick,
    required this.video,
    required this.outgoing,
    required this.phase,
    this.muted = false,
    this.cameraOff = false,
    this.sharingScreen = false,
    this.remoteVideo = false,
    this.linkDown = false,
    this.minimized = false,
    this.dmId,
  });

  final String callId;
  final String peerNick;
  final bool video;
  final bool outgoing;
  final CallPhase phase;
  final bool muted;
  final bool cameraOff;
  final bool sharingScreen;

  /// A remote video track arrived (avatar shown until then, §22/§41).
  final bool remoteVideo;

  /// Transport wobble: show "reconnecting", never auto-hangup (§57).
  final bool linkDown;

  /// Presentation only: mini overlay vs centered window (§46–§48).
  final bool minimized;

  /// DM this call belongs to, if dialed by dm (group redial needs it:
  /// group calls have no peer nick).
  final String? dmId;

  ActiveCall copyWith({
    CallPhase? phase,
    bool? muted,
    bool? cameraOff,
    bool? sharingScreen,
    bool? remoteVideo,
    bool? linkDown,
    bool? minimized,
  }) =>
      ActiveCall(
        callId: callId,
        peerNick: peerNick,
        video: video,
        outgoing: outgoing,
        phase: phase ?? this.phase,
        muted: muted ?? this.muted,
        cameraOff: cameraOff ?? this.cameraOff,
        sharingScreen: sharingScreen ?? this.sharingScreen,
        remoteVideo: remoteVideo ?? this.remoteVideo,
        linkDown: linkDown ?? this.linkDown,
        minimized: minimized ?? this.minimized,
        dmId: dmId,
      );
}

final callApiProvider = Provider<CallApi>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) throw StateError('no session');
  return CallApi(ref.watch(connectionProvider), s);
});

/// Ringing state for the callee.
///
/// [remoteVideoArrived] must be carried in explicitly: onTrack fires while
/// `setRemoteDescription` runs, i.e. *before* this state is published, and a
/// freshly built [ActiveCall] would default `remoteVideo` back to false. The
/// result is a callee that stays on "Подключение видео…" even though the
/// remote camera track is right there in the renderer.
ActiveCall incomingRingingCall({
  required String callId,
  required String peerNick,
  required bool video,
  required bool remoteVideoArrived,
}) =>
    ActiveCall(
        callId: callId,
        peerNick: peerNick,
        video: video,
        outgoing: false,
        remoteVideo: remoteVideoArrived,
        phase: CallPhase.ringing);

class CallState extends Notifier<ActiveCall?> {
  RTCPeerConnection? _pc;
  MediaStream? _local;
  RTCVideoRenderer? _localR;
  RTCVideoRenderer? _remoteR;
  RTCRtpSender? _videoSender;
  MediaStream? _screen;
  Timer? _ringTimer;
  /// Quality sampler: while a call is active, a getStats digest lands in
  /// the desktop log every 10s (dlog only — no UI, no uploads). Gives real
  /// RTT/jitter/loss/frames for the next "плохо слышно/видно" report
  /// instead of guessing.
  Timer? _statsTimer;
  StreamSubscription<Map<String, dynamic>>? _pushSub;
  final _pendingIce = <Map<String, String?>>[];
  String? _callId;

  /// Dry-ring offer (§25): the remote SDP waits here until accept, so an
  /// incoming call holds NO microphone/camera while it rings. Media starts
  /// in [acceptIncoming], never before.
  String? _pendingOfferSdp;

  // Remote side (§15, §20): candidates before setRemoteDescription wait
  // in [_remoteIce]; remote tracks land in [_remoteStream].
  final _remoteIce = IceBuffer<Map<String, String?>>();
  MediaStream? _remoteStream;
  bool _remoteDescSet = false;

  /// A live call hidden under a ringing incoming (call waiting): its
  /// transport keeps running untouched (dry ring) until decline restores
  /// it or an atomic switch ends it. Null in the common case.
  ActiveCall? _displaced;

  /// A remote video track has arrived at least once. Tracked separately from
  /// [ActiveCall.remoteVideo] because _prepareIncoming rebuilds the ringing
  /// state from scratch *after* setRemoteDescription, and onTrack has already
  /// fired by then - a fresh object would silently drop the flag and leave
  /// the callee staring at "Подключение видео…" forever.
  bool _remoteVideoArrived = false;

  /// Call tones (P2P only): RU ringback while dialling, a short blip when
  /// a call ends or an outgoing attempt fails. Delegated to [CallTones]:
  /// audioplayers touches a platform channel whose headless init cannot be
  /// try/caught, so engine code never constructs AudioPlayer directly.
  Future<void> _startRingback() =>
      ref.read(callTonesProvider).startRingback();

  Future<void> _stopRingback() => ref.read(callTonesProvider).stopRingback();

  Future<void> _playEndTone() async {
    ref.read(callTonesProvider).endBlip();
  }

  /// User-facing end blip: the current call audibly ended or a dial failed.
  /// Read-only wrt state; safe to call from UI hangup buttons and the
  /// redial watchdog. The coordinator NEVER calls this — session switches
  /// stay silent by construction (no cancel blip on accept).
  void toneForLocalEnd() {
    final cur = state;
    if (cur == null) return;
    if (cur.phase == CallPhase.active || cur.outgoing) {
      unawaited(_playEndTone());
    }
  }

  RTCVideoRenderer? get localRenderer => _localR;
  RTCVideoRenderer? get remoteRenderer => _remoteR;

  @override
  ActiveCall? build() => null;

  void ensureListening() {
    _pushSub ??=
        ref.read(connectionProvider).pushes.listen(_onPush);
  }

  Future<Map<String, dynamic>> _rtcConfig() async {
    final servers = <Map<String, dynamic>>[
      {
        'urls': ['stun:stun.l.google.com:19302']
      },
    ];
    try {
      final turn = await ref.read(callApiProvider).turnCredentials();
      if (turn != null) {
        servers.add({
          'urls': (turn['urls'] as List).map((e) => e.toString()).toList(),
          'username': turn['username'],
          'credential': turn['password'],
        });
      }
    } catch (_) {}
    return {'iceServers': servers, 'sdpSemantics': 'unified-plan'};
  }

  Future<RTCPeerConnection> _newPc(String callId) async {
    final pc = await createPeerConnection(await _rtcConfig(), {});
    _remoteDescSet = false;
    _remoteIce.clear();
    _remoteVideoArrived = false;
    pc.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      dlog('ice local candidate ${iceDigest(c.candidate)} '
          'sdpMid=${c.sdpMid} mline=${c.sdpMLineIndex}');
      final payload = {
        'candidate': c.candidate!,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex?.toString(),
      };
      if (_callId == null) {
        _pendingIce.add(payload);
      } else {
        ref.read(callApiProvider).ice(
            callId: _callId!,
            candidate: payload['candidate']!,
            sdpMid: payload['sdpMid'],
            sdpMLineIndex: payload['sdpMLineIndex']).catchError((_) {});
      }
    };
    pc.onSignalingState = (s) => dlog('pc signaling=$s');
    pc.onIceGatheringState = (s) => dlog('pc iceGathering=$s');
    pc.onConnectionState = (s) {
      dlog('pc connection=$s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        state = state?.copyWith(linkDown: false);
        _startQuality();
        _logStatsSnapshot('connected');
      } else if (s ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        // Never auto-hangup on a wobble (§57): banner only.
        if (state?.phase == CallPhase.active) {
          state = state?.copyWith(linkDown: true);
        }
      }
    };
    pc.onIceConnectionState = (s) => dlog('pc iceConnection=$s');
    pc.onTrack = (ev) => _onTrack(ev);
    // Legacy fallback: Unified Plan delivers via onTrack; keep for old
    // endpoints, but never let it clobber the onTrack stream.
    pc.onAddStream = (s) {
      if (_remoteR?.srcObject == null) {
        dlog('onAddStream fallback streams=1');
        _remoteR?.srcObject = s;
        state = state?.copyWith();
      }
    };
    return pc;
  }

  /// Remote track arrival (§17, §20, §21): never drop, never reuse the
  /// local renderer, never recreate renderers per event.
  Future<void> _onTrack(RTCTrackEvent ev) async {
    final track = ev.track;
    dlog('onTrack kind=${track.kind} id=${track.id} '
        'enabled=${track.enabled} streams=${ev.streams.length}');
    try {
      var remote = _remoteStream;
      if (remote == null) {
        if (ev.streams.isNotEmpty) {
          remote = ev.streams.first;
          dlog('remote stream from event');
        } else {
          remote = await createLocalMediaStream('grchat-remote');
          dlog('remote stream created locally (no event stream)');
        }
        _remoteStream = remote;
      }
      final known =
          remote.getTracks().any((t) => t.id == track.id);
      if (!known) {
        try {
          await remote.addTrack(track);
        } catch (_) {
          // Already attached natively; binding below is what matters.
        }
      }
      _remoteR?.srcObject ??= remote;
      if (track.kind == 'video') {
        _remoteVideoArrived = true;
        state = state?.copyWith(remoteVideo: true);
      } else {
        state = state?.copyWith();
      }
      _logStatsSnapshot('ontrack-${track.kind}');
    } catch (e) {
      dlog('onTrack failed: $e');
    }
  }

  // --- Adaptive send quality (P2P) ------------------------------------------
  // The camera is captured once at the best mode it offers (1080p/60 asked
  // for). What is SENT is steered by a tier ladder (eco 540p30 ... max
  // 1080p60): a call starts at 720p30, climbs while the link AND the CPU
  // keep up, and steps back down when they do not. See quality_tier.dart.

  /// How often the link is sampled.
  static const _qualityPeriod = Duration(seconds: 3);

  QualityController? _quality;
  Timer? _qualityTimer;
  bool _qualityBusy = false;
  RTCRtpSender? _audioSender;

  /// Logged "no outgoing video" state (once per stall episode).
  bool _qualityStallLogged = false;

  /// Real capture height, learned from the sent frames (see _qualityTick).
  /// 0 = not known yet: no downscale is applied until it is.
  int _captureHeight = 0;

  /// No learning before this moment (stats may lag a source switch).
  DateTime _learnHoldUntil = DateTime.fromMillisecondsSinceEpoch(0);

  void _holdLearning() =>
      _learnHoldUntil = DateTime.now().add(_qualityPeriod * 2);

  /// Start (or re-apply) quality control once the connection is up. Idempotent:
  /// "connected" can fire again after an ICE restart.
  void _startQuality() {
    _applyAudio();
    if (_videoSender == null) return; // audio-only call
    final now = DateTime.now();
    _quality = _quality ?? QualityController(startedAt: now);
    // Re-arm the warmup clock on a fresh connected (e.g. after ICE restart:
    // the bandwidth estimate starts over at its dummy value).
    _quality!.markConnected(now);
    _applyTier();
    _qualityTimer ??= Timer.periodic(_qualityPeriod, (_) => _qualityTick());
  }

  void _stopQuality() {
    _qualityTimer?.cancel();
    _qualityTimer = null;
    _quality = null;
    _qualityBusy = false;
    _qualityStallLogged = false;
    _audioSender = null;
    _captureHeight = 0;
    _learnHoldUntil = DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> _qualityTick() async {
    final pc = _pc;
    final q = _quality;
    if (_qualityBusy || pc == null || q == null) return;
    if (state?.phase != CallPhase.active) return;
    _qualityBusy = true;
    try {
      final m = LinkMetrics.fromReports(await pc.getStats());
      // Learn the camera's real height. getSettings() on desktop only echoes
      // the REQUESTED mode, but a SENT frame is never taller than the
      // captured one, so the largest height seen can only under-estimate
      // (harmless: it converges upward as the encoder ramps up), never
      // over-estimate. Screen frames are excluded, and just after a share
      // toggle the stats may still describe the other source.
      final fh = m.frameHeight;
      if (fh != null &&
          _screen == null &&
          !DateTime.now().isBefore(_learnHoldUntil) &&
          fh.round() > _captureHeight) {
        _captureHeight = fh.round();
        dlog('capture height learned: ${_captureHeight}p');
        await _applyTier();
      }
      final changed = q.update(m, DateTime.now());
      if (changed != null) {
        dlog('video tier -> $changed '
            '(avail=${m.availableOutKbps?.round()}kbps '
            'rtt=${m.rttMs?.round()}ms loss=${m.lossPct?.toStringAsFixed(1)}% '
            'limit=${m.limitation})');
        await _applyTier();
      }
      // One diagnostics line per tick (the numbers round to integers; a
      // missing value prints as '-').
      String n(Object? v) =>
          v is double ? v.round().toString() : (v?.toString() ?? '-');
      final frameW = m.frameWidth?.round(),
          frameH = m.frameHeight?.round();
      dlog('quality: tier=${q.tier.name} '
          'avail=${n(m.availableOutKbps)} sent=${n(q.sentKbps)} '
          'fps=${n(m.framesPerSecond)} '
          'frame=${(frameW != null && frameH != null && frameW > 0 && frameH > 0) ? '${frameW}x$frameH' : '-'} '
          'rtt=${n(m.rttMs)} '
          'loss=${m.lossPct?.toStringAsFixed(1) ?? '-'}% '
          'limit=${m.limitation ?? '-'}');
      if (q.videoStalled && !_qualityStallLogged) {
        _qualityStallLogged = true;
        dlog('quality: no outgoing video (bytes frozen) — tier control paused');
      } else if (!q.videoStalled) {
        _qualityStallLogged = false;
      }
      final lowFps = q.consumeLowFpsWarning();
      if (lowFps != null) dlog(lowFps);
    } catch (e) {
      dlog('quality tick failed: $e');
    } finally {
      _qualityBusy = false;
    }
  }

  /// Push the current tier into the video sender. Best effort: a platform
  /// that rejects setParameters keeps WebRTC's own adaptation, the call
  /// itself is never affected.
  Future<void> _applyTier() async {
    final sender = _videoSender;
    final q = _quality;
    if (sender == null || q == null) return;
    try {
      final p = sender.parameters;
      final enc = p.encodings;
      if (enc == null || enc.isEmpty) {
        dlog('tier apply skipped: no encodings');
        return;
      }
      // A shared screen is not camera-sized: never downscale it by a
      // camera-derived factor, and keep text sharp over smooth motion.
      final sharing = _screen != null;
      final tp = tierParams(q.tier,
          captureHeight: sharing ? 0 : _captureHeight, captureFps: 0);
      for (final e in enc) {
        e.maxBitrate = tp.maxBitrate;
        e.maxFramerate = tp.maxFramerate;
        e.scaleResolutionDownBy = tp.scaleDownBy;
      }
      p.degradationPreference = sharing
          ? RTCDegradationPreference.MAINTAIN_RESOLUTION
          : RTCDegradationPreference.BALANCED;
      final ok = await sender.setParameters(p);
      dlog('video tier ${q.tier} scale=${tp.scaleDownBy.toStringAsFixed(2)} '
          'fps<=${tp.maxFramerate} applied=$ok');
    } catch (e) {
      dlog('video tier apply failed: $e');
    }
  }

  /// Audio send ceiling matching the Opus fmtp we negotiate (sdp_tuning).
  Future<void> _applyAudio() async {
    final sender = _audioSender;
    if (sender == null) return;
    try {
      final p = sender.parameters;
      final enc = p.encodings;
      if (enc == null || enc.isEmpty) return;
      for (final e in enc) {
        e.maxBitrate = opusSenderMaxBitrate;
      }
      final ok = await sender.setParameters(p);
      dlog('audio cap ${opusSenderMaxBitrate ~/ 1000}kbps applied=$ok');
    } catch (e) {
      dlog('audio cap failed: $e');
    }
  }

  /// Camera/mic capture. flutter_webrtc on desktop has no per-device
  /// capability query and drivers open "whatever they can", so the probe
  /// asks candidate profiles one by one, reads the REAL result via
  /// getSettings(), keeps the best capture (most pixels, then fps) and
  /// frees the rest. The winner is recommended to the tier logic as the
  /// device's actual mode (capture height from the driver, not guessed).
  Future<MediaStream> _openLocalMedia(bool video) async {
    // Echo cancellation, noise suppression and auto gain stay on; the
    // high-pass filter removes desk/fan rumble that costs bits and clarity.
    final audio = {
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      'highpassFilter': true,
    };
    Map<String, dynamic> cam(int w, int h, int fps) => {
          'width': {'ideal': w},
          'height': {'ideal': h},
          'frameRate': {'ideal': fps},
        };
    if (!video) {
      return navigator.mediaDevices
          .getUserMedia({'audio': audio, 'video': false});
    }
    // Cross-process arbitration: another grchat instance may already own
    // the camera. Rather than both sides "opening" the device and getting
    // zero frames, this instance goes audio-only and stays a receiver.
    if (!CameraLock.acquire()) {
      dlog('camera busy (another grchat instance owns it), joining audio-only');
      return navigator.mediaDevices
          .getUserMedia({'audio': audio, 'video': false});
    }
    const candidates = [(1920, 1080, 30), (1280, 720, 60), (1280, 720, 30),
        (640, 480, 30)];
    MediaStream? best;
    var bestPixels = 0;
    var bestFps = 0.0;
    for (final c in candidates) {
      MediaStream s;
      try {
        s = await navigator.mediaDevices
            .getUserMedia({'audio': audio, 'video': cam(c.$1, c.$2, c.$3)});
      } catch (e) {
        dlog('camera probe ${c.$2}p refused ($e)');
        continue;
      }
      int w = 0, h = 0;
      double f = 0;
      try {
        final tracks = s.getVideoTracks();
        final st = tracks.isEmpty ? null : tracks.first.getSettings();
        w = (st?['width'] as num?)?.round() ?? 0;
        h = (st?['height'] as num?)?.round() ?? 0;
        f = (st?['frameRate'] as num?)?.toDouble() ?? 0;
      } catch (_) {}
      dlog('camera probe ${c.$1}x${c.$2}@${c.$3} -> $w x $h @${f.round()}');
      // Pixels dominate, fps breaks ties: capture can always be downscaled      // later, but never upscaled.
      final pixels = w * h;
      if (pixels > bestPixels ||
          (pixels == bestPixels && f > bestFps)) {
        await best?.dispose();
        best = s;
        bestPixels = pixels;
        bestFps = f;
      } else {
        await s.dispose();
      }
    }
    final stream = best;
    if (stream == null) {
      // Everything was refused; last resort so the call still connects.
      dlog('camera probes all refused, falling back to 720p30');
      return navigator.mediaDevices
          .getUserMedia({'audio': audio, 'video': cam(1280, 720, 30)});
    }
    // Capture height for the tier logic: the driver's report is the TRUE
    // device mode. Outbound learning (from sent frames) sticks at the
    // downscaled height after a tier shrinks the stream, so it can only
    // under-estimate; weight the observed fps too.
    try {
      final tracks = stream.getVideoTracks();
      final st = tracks.isEmpty ? null : tracks.first.getSettings();
      final h = (st?['height'] as num?)?.round() ?? 0;
      if (h > _captureHeight) {
        _captureHeight = h;
        dlog('capture height from driver: ${_captureHeight}p');
      }
    } catch (_) {}
    return stream;
  }

  Future<void> _addLocal(RTCPeerConnection pc, bool video) async {
    _local = await _openLocalMedia(video);
    final tracks = _local!.getTracks();
    dlog('getUserMedia audio=${_local!.getAudioTracks().length} '
        'video=${_local!.getVideoTracks().length}');
    for (final t in tracks) {
      dlog('local track kind=${t.kind} id=${t.id} enabled=${t.enabled}');
      final sender = await pc.addTrack(t, _local!);
      if (t.kind == 'video') _videoSender = sender;
      if (t.kind == 'audio') _audioSender = sender;
    }
    dlog('senders=${(await pc.getSenders()).length}');
    if (video) {
      _localR = RTCVideoRenderer();
      await _localR!.initialize();
      _localR!.srcObject = _local;
    }
    _remoteR = RTCVideoRenderer();
    await _remoteR!.initialize();
  }

  Future<void> startCall(
      {String? peerNick, String? dmId, required bool video}) async {
    if (state != null) return;
    // A pending redial belongs to the previous attempt.
    ref.read(callRedialProvider.notifier).clear();
    final api = ref.read(callApiProvider);
    final name = peerNick ?? 'Группа';
    state = ActiveCall(
        callId: '', peerNick: name, video: video, outgoing: true, phase: CallPhase.ringing);
    // Dialling feedback starts with the ring, not with the network.
    unawaited(_startRingback());
    try {
      _pc = await _newPc('');
      await _addLocal(_pc!, video);
      final rawOffer = await _pc!.createOffer({});
      final offer = RTCSessionDescription(
          tuneOpusSdp(rawOffer.sdp ?? ''), rawOffer.type);
      await _pc!.setLocalDescription(offer);
      final sdp = (await _pc!.getLocalDescription())?.sdp ?? '';
      dlog('offer ${SdpSummary.parse(sdp)}');
      final callId =
          await api.offer(peerNick: peerNick, dmId: dmId, sdp: sdp);
      _callId = callId;
      state = state?.copyWith();
      for (final p in _pendingIce) {
        api
            .ice(
                callId: callId,
                candidate: p['candidate']!,
                sdpMid: p['sdpMid'],
                sdpMLineIndex: p['sdpMLineIndex'])
            .catchError((_) {});
      }
      _pendingIce.clear();
      // refresh state object with real call id
      final cur = state;
      if (cur != null) {
        state = ActiveCall(
            callId: callId,
            peerNick: cur.peerNick,
            video: cur.video,
            outgoing: true,
            dmId: dmId,
            phase: CallPhase.ringing);
        // Unanswered outgoing: stop ringing before the server sweep (60s).
        // Offer redial (§94) instead of a dead-end toast.
        _armUnansweredTimeout(
            callId: callId,
            peerNick: peerNick,
            dmId: dmId,
            video: video);
      }
    } catch (e) {
      await _cleanup();
      rethrow;
    }
  }

  /// Starts the 10s quality sampler; idempotent. Stopped in [_cleanup].
  void _armStatsTick() {
    _statsTimer?.cancel();
    var n = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final cur = state;
      if (cur == null || cur.phase != CallPhase.active || _pc == null) {
        return;
      }
      unawaited(_logStatsSnapshot('tick-${++n}'));
    });
  }

  /// Unanswered-outgoing watchdog: redial offer (§94) instead of ringing
  /// into the server sweep. Re-armed when a displaced dial-out resurfaces
  /// after a declined/waiting incoming.
  void _armUnansweredTimeout(
      {required String callId,
      String? peerNick,
      String? dmId,
      required bool video}) {
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 50), () async {
      final c = state;
      if (c == null ||
          c.callId != callId ||
          c.phase != CallPhase.ringing) {
        return;
      }
      ref.read(callRedialProvider.notifier).offer(CallRedial(
          reason: 'Нет ответа',
          peerNick: peerNick,
          dmId: dmId,
          video: video));
      // Unanswered dial: audible cancel before teardown.
      toneForLocalEnd();
      await hangup();
    });
  }

  Future<void> acceptIncoming() async {
    final cur = state;
    if (cur == null || cur.outgoing) return;
    ref.read(callRedialProvider.notifier).clear();
    final api = ref.read(callApiProvider);
    try {
      if (_pc == null) {
        // Dry ring: the microphone/camera start only now, at accept time.
        // The old session (if any) was already ended by the coordinator,
        // so these fields are free — never two live transports (§1).
        _pc = await _newPc(cur.callId);
        await _addLocal(_pc!, cur.video);
        dlog('offer ${SdpSummary.parse(_pendingOfferSdp ?? '')}');
        await _pc!.setRemoteDescription(RTCSessionDescription(
            _pendingOfferSdp ?? '', 'offer'));
        _remoteDescSet = true;
        await _flushRemoteIce();
        if (_remoteVideoArrived) {
          state = state?.copyWith(remoteVideo: true);
        }
      }
      final rawAnswer = await _pc!.createAnswer({});
      final answer = RTCSessionDescription(
          tuneOpusSdp(rawAnswer.sdp ?? ''), rawAnswer.type);
      await _pc!.setLocalDescription(answer);
      final sdp = (await _pc!.getLocalDescription())?.sdp ?? '';
      dlog('answer ${SdpSummary.parse(sdp)}');
      await api.answer(callId: cur.callId, accept: true, sdp: sdp);
      _ringTimer?.cancel();
      // Patch the live state instead of writing back the pre-await snapshot:
      // onTrack may have delivered a remote video track meanwhile.
      state = state?.copyWith(phase: CallPhase.active);
      _armStatsTick();
    } catch (e) {
      await decline();
      rethrow;
    }
  }

  Future<void> decline() async {
    final cur = state;
    if (cur == null) return;
    final disp = _displaced;
    _displaced = null;
    try {
      await ref.read(callApiProvider).answer(callId: cur.callId, accept: false);
    } catch (_) {}
    if (disp != null) {
      // A live call was waiting under this ring: resurface it. Dry ring
      // never touched its transport, so only the state comes back — plus
      // its unanswered timeout if it was still dialling out (the ring
      // overwrote the timer reference).
      _ringTimer?.cancel();
      _ringTimer = null;
      state = disp;
      if (disp.outgoing && disp.phase == CallPhase.ringing) {
        _armUnansweredTimeout(
            callId: disp.callId,
            peerNick: disp.dmId == null ? disp.peerNick : null,
            dmId: disp.dmId,
            video: disp.video);
      }
      return;
    }
    await _cleanup();
  }

  Future<void> hangup() async {
    await endAll();
  }

  /// Coordinator primitive: end everything this engine holds, with the
  /// right verb per occupancy (hangup for live, decline for a bare ring).
  /// The accepted pending ([exceptPendingId]) keeps its dry offer while a
  /// displaced transport underneath is dropped. Idempotent (§38).
  Future<void> endAll({String? exceptPendingId}) async {
    final cur = state;
    if (cur != null &&
        !cur.outgoing &&
        cur.phase == CallPhase.ringing &&
        cur.callId == exceptPendingId) {
      await endDisplacedForSwitch();
      return;
    }
    final disp = _displaced;
    _displaced = null;
    if (disp != null) {
      try {
        await ref.read(callApiProvider).hangup(disp.callId);
      } catch (_) {}
    }
    if (cur == null) {
      await _cleanup();
      return;
    }
    if (!cur.outgoing && cur.phase == CallPhase.ringing) {
      try {
        await ref
            .read(callApiProvider)
            .answer(callId: cur.callId, accept: false);
      } catch (_) {}
      await _cleanup();
    } else {
      try {
        await ref.read(callApiProvider).hangup(cur.callId);
      } catch (_) {}
      await _cleanup();
    }
  }

  /// Drop a displaced live call for an atomic switch: signaling hangup for
  /// the old peer, local transport closed. The ringing pending (state,
  /// offer, queued ICE) is untouched — the accept that follows owns it.
  Future<void> endDisplacedForSwitch() async {
    final disp = _displaced;
    _displaced = null;
    if (disp == null) return;
    dlog('displaced call ended for switch ${disp.callId}');
    try {
      await ref.read(callApiProvider).hangup(disp.callId);
    } catch (_) {}
    await _closeTransport();
    _pendingIce.clear();
  }

  void toggleMute() {
    final cur = state;
    if (cur == null) return;
    final muted = !cur.muted;
    _local?.getAudioTracks().forEach((t) => t.enabled = !muted);
    state = cur.copyWith(muted: muted);
  }

  void toggleCamera() {
    final cur = state;
    if (cur == null || !cur.video) return;
    final off = !cur.cameraOff;
    _local?.getVideoTracks().forEach((t) => t.enabled = !off);
    state = cur.copyWith(cameraOff: off);
  }

  /// Screen share replaces the camera track in place (no renegotiation:
  /// same video m-line, so the remote side just sees the new picture).
  /// Desktop-only button: active video calls.
  Future<void> toggleScreenShare() async {
    final cur = state;
    final pc = _pc;
    if (cur == null ||
        !cur.video ||
        cur.phase != CallPhase.active ||
        pc == null) {
      return;
    }
    try {
      if (_screen == null) {
        dlog('screenshare start');
        final stream =
            await navigator.mediaDevices.getDisplayMedia({'video': true});
        final n = stream.getVideoTracks().length;
        dlog('screenshare stream videoTracks=$n');
        if (stream.getVideoTracks().isEmpty) {
          await stream.dispose();
          dlog('screenshare empty tracks (picker closed?)');
          return;
        }
        final sender = _videoSender;
        if (sender == null) {
          await stream.dispose();
          dlog('screenshare no video sender');
          _notice('Не вышло показать экран');
          return;
        }
        await sender
            .replaceTrack(stream.getVideoTracks().first);
        _screen = stream;
        _localR?.srcObject = stream;
        dlog('screenshare sharing');
        state = state?.copyWith(sharingScreen: true);
        _holdLearning();
        _applyTier();
      } else {
        final cam = _local?.getVideoTracks();
        final sender = _videoSender;
        if (sender != null && cam != null && cam.isNotEmpty) {
          await sender.replaceTrack(cam.first);
        }
        for (final t in _screen!.getTracks()) {
          try {
            await t.stop();
          } catch (_) {}
        }
        try {
          await _screen!.dispose();
        } catch (_) {}
        _screen = null;
        if (_localR != null) _localR!.srcObject = _local;
        state = state?.copyWith(sharingScreen: false);
        _holdLearning();
        _applyTier();
      }
    } catch (e) {
      // User closed the picker or capture failed: stay on camera, but say so.
      dlog('screenshare failed: $e');
      _notice('Не вышло показать экран');
    }
  }

  /// getStats digest (§25–§26). Debug-logged; use the returned string
  /// for the debug call summary (§27).
  Future<String> diagnosticsSummary() async {
    final pc = _pc;
    final cur = state;
    if (pc == null || cur == null) return 'no call';
    try {
      final stats = StatsSummary.summarize(await pc.getStats());
      final local = _local;
      final remoteAudio =
          _remoteStream?.getAudioTracks().isNotEmpty ?? false;
      final remoteVideo =
          _remoteStream?.getVideoTracks().isNotEmpty ?? false;
      return buildDebugSummary(
          platform: platformTag(),
          callId: cur.callId,
          role: cur.outgoing ? 'caller' : 'callee',
          localAudioTracks: local?.getAudioTracks().length ?? 0,
          localVideoTracks: local?.getVideoTracks().length ?? 0,
          signalingState:
              (await pc.getSignalingState()).toString(),
          iceGatheringState:
              (await pc.getIceGatheringState()).toString(),
          iceConnectionState:
              (await pc.getIceConnectionState()).toString(),
          connectionState:
              (await pc.getConnectionState()).toString(),
          remoteAudio: remoteAudio,
          remoteVideo: remoteVideo,
          stats: stats);
    } catch (e) {
      return 'stats failed: $e';
    }
  }

  Future<void> _logStatsSnapshot(String why) async {
    try {
      dlog('stats [$why]\n${await diagnosticsSummary()}');
    } catch (_) {}
  }

  void setMinimized(bool minimized) {
    final cur = state;
    if (cur == null || cur.minimized == minimized) return;
    state = cur.copyWith(minimized: minimized);
  }

  void _notice(String text) {
    ref.read(callNoticeProvider.notifier).show(text);
  }

  void _onPush(Map<String, dynamic> ev) {
    switch (ev['type']?.toString()) {
      case 'call_incoming':
        final marker =
            parseSfuMarker((ev['sdp'] ?? '').toString());
        if (marker != null) {
          _routeGroupInvite(ev, marker);
          return;
        }
        // Single pending at a time (§16): a switch running or an unanswered
        // ring means BUSY for the next caller. Anything merely active gets
        // call waiting instead (§45) — dry ring holds no media (§25), and
        // accept is an atomic coordinator switch, never a second session.
        final coord = ref.read(mediaCoordinatorProvider.notifier);
        final id = ev['call_id']?.toString();
        if (coord.switching || coord.hasPendingIncoming()) {
          if (id != null) {
            try {
              ref
                  .read(callApiProvider)
                  .answer(callId: id, accept: false)
                  .catchError((_) {});
            } catch (_) {}
          }
          return;
        }
        _prepareIncoming(ev);
      case 'call_accepted':
        _onAccepted(ev);
      case 'ice':
        _onRemoteIce(ev);
      case 'call_ended':
        _onEnded(ev);
    }
  }

  /// SFU group invite (marker sdp): route to the group stack, never P2P.
  void _routeGroupInvite(
      Map<String, dynamic> ev, ({String room, bool video}) marker) {
    const prefix = 'grchat_';
    if (!marker.room.startsWith(prefix)) return;
    final dmId = marker.room.substring(prefix.length);
    if (dmId.isEmpty) return;
    final callId = ev['call_id']?.toString();
    if (callId == null) return;
    ref.read(groupCallProvider.notifier).incoming(
        callId: callId,
        dmId: dmId,
        room: marker.room,
        video: marker.video,
        fromNick: (ev['from_nick'] ?? '?').toString());
  }

  /// Caller side: the answer SDP must become the remote description,
  /// otherwise signaling completes but no media flows.
  Future<void> _onAccepted(Map<String, dynamic> ev) async {
    final cur = state;
    if (cur == null ||
        !cur.outgoing ||
        ev['call_id'] != cur.callId) {
      return;
    }
    try {
      final sdp = (ev['sdp'] ?? '').toString();
      if (sdp.isNotEmpty) {
        dlog('answer ${SdpSummary.parse(sdp)}');
        await _pc?.setRemoteDescription(
            RTCSessionDescription(sdp, 'answer'));
        _remoteDescSet = true;
        await _flushRemoteIce();
      }
      _ringTimer?.cancel();
      // Patch the live state, not the pre-await snapshot (see acceptIncoming).
      state = state?.copyWith(phase: CallPhase.active);
      // Answered: media is live, the ringback must die right here.
      unawaited(_stopRingback());
      _armStatsTick();
    } catch (_) {
      await hangup();
    }
  }

  void _onEnded(Map<String, dynamic> ev) {
    unawaited(_onEndedAsync(ev));
  }

  Future<void> _onEndedAsync(Map<String, dynamic> ev) async {
    final cur = state;
    if (cur == null || ev['call_id'] != cur.callId) {
      // Late end for a call hidden under a ring (§39): it is already gone
      // remotely — drop it so a later decline cannot resurrect a ghost.
      final disp = _displaced;
      if (disp != null && ev['call_id'] == disp.callId) {
        dlog('displaced call ended remotely ${disp.callId}');
        _displaced = null;
        _closeTransport();
        _pendingIce.clear();
        // It was live until the remote end: audible feedback applies.
        unawaited(_playEndTone());
      }
      return;
    }
    final reason = ev['reason']?.toString() ?? '';
    final by = (ev['by_nick'] ?? cur.peerNick).toString();
    final wasPending = !cur.outgoing && cur.phase == CallPhase.ringing;
    // Audible end: a live call torn down remotely, or a dial that failed.
    // A dismissed incoming stays silent; a resurfaced displaced call never
    // ended from the user's perspective.
    if (cur.phase == CallPhase.active ||
        (cur.phase == CallPhase.ringing && cur.outgoing)) {
      unawaited(_playEndTone());
    }
    if (cur.phase == CallPhase.ringing) {
      if (cur.outgoing) {
        // Unanswered either way (decline or timeout race): redial §94.
        // Group dials redial by dm; 1-1 by nick ('Группа' is a label).
        ref.read(callRedialProvider.notifier).offer(CallRedial(
            reason: reason == 'declined' ? '$by отклонил звонок' : 'Нет ответа',
            peerNick: cur.dmId == null ? cur.peerNick : null,
            dmId: cur.dmId,
            video: cur.video));
      } else {
        _notice('Пропущенный звонок от ${cur.peerNick}');
      }
    }
    final disp = _displaced;
    _displaced = null;
    if (disp != null && wasPending) {
      // The ring ended remotely with a live call underneath: it resurfaces,
      // media untouched (dry ring never took it).
      _ringTimer?.cancel();
      _ringTimer = null;
      _pendingOfferSdp = null;
      state = disp;
      if (disp.outgoing && disp.phase == CallPhase.ringing) {
        _armUnansweredTimeout(
            callId: disp.callId,
            peerNick: disp.dmId == null ? disp.peerNick : null,
            dmId: disp.dmId,
            video: disp.video);
      }
      return;
    }
    await _cleanup();
  }

  /// Test seam: drive a dry-ring incoming without WebRTC (headless-safe:
  /// no PC or media is created at ring time by design).
  @visibleForTesting
  Future<void> debugIncomingForTest(
          {required String callId,
          required String peerNick,
          required bool video,
          String sdp = ''}) =>
      _prepareIncoming(
          {'call_id': callId, 'from_nick': peerNick, 'sdp': sdp});

  /// Test seam: the live call hidden under a ringing incoming, if any.
  @visibleForTesting
  ActiveCall? get debugDisplacedForTest => _displaced;

  /// Test seam: remote ended a call by id. Awaits the async teardown so
  /// tests can assert the settled state (push path itself is fire-and-forget).
  @visibleForTesting
  Future<void> debugRemoteEndedForTest(String callId) =>
      _onEndedAsync({'call_id': callId});

  Future<void> _prepareIncoming(Map<String, dynamic> ev) async {
    ActiveCall? stashed;
    try {
      ref.read(callRedialProvider.notifier).clear();
      final callId = ev['call_id'] as String;
      final sdp = (ev['sdp'] ?? '') as String;
      final video = sdp.contains('m=video');
      // Call waiting: a live session keeps running under this ring (its
      // transport is untouched until decline restores it or a switch ends
      // it). Never two actives — the ring itself holds no media.
      final cur = state;
      if (cur != null && (cur.outgoing || cur.phase != CallPhase.ringing)) {
        _displaced = cur;
        stashed = cur;
      }
      _callId = callId;
      // Dry ring (§25): the offer waits for accept; no PeerConnection and
      // no microphone/camera while it rings, even over a live session.
      _pendingOfferSdp = sdp;
      dlog('offer ${SdpSummary.parse(sdp)} (dry ring)');
      state = incomingRingingCall(
          callId: callId,
          peerNick: (ev['from_nick'] ?? '?') as String,
          video: video,
          // No setRemoteDescription ran yet: nothing could have arrived.
          remoteVideoArrived: false);
      // Safety net if the caller never hangs up (old client / no sweep).
      _ringTimer?.cancel();
      _ringTimer = Timer(const Duration(seconds: 58), () async {
        final c = state;
        if (c == null ||
            c.callId != callId ||
            c.phase != CallPhase.ringing) {
          return;
        }
        _notice('Пропущенный звонок от ${c.peerNick}');
        await decline();
      });
    } catch (_) {
      if (stashed != null) {
        _displaced = null;
        state = stashed;
      } else {
        await _cleanup();
      }
    }
  }

  Future<void> _onRemoteIce(Map<String, dynamic> ev) async {
    final pc = _pc;
    if (state == null || ev['call_id'] != state!.callId) return;
    final payload = {
      'candidate': (ev['candidate'] ?? '').toString(),
      'sdpMid': ev['sdp_mid']?.toString(),
      'sdpMLineIndex': ev['sdp_mline_index']?.toString(),
    };
    if (!_remoteDescSet || pc == null) {
      // Race (§15) or dry ring: queue, never drop.
      dlog('ice remote queued (no remote description yet)');
      _remoteIce.add(payload);
      return;
    }
    await _addRemoteCandidate(pc, payload);
  }

  Future<void> _flushRemoteIce() async {
    final pc = _pc;
    final queued = _remoteIce.drain();
    if (queued.isEmpty || pc == null) return;
    dlog('ice remote flushing ${queued.length} queued');
    for (final p in queued) {
      await _addRemoteCandidate(pc, p);
    }
  }

  Future<void> _addRemoteCandidate(
      RTCPeerConnection pc, Map<String, String?> p) async {
    try {
      await pc.addCandidate(RTCIceCandidate(
        p['candidate'] ?? '',
        p['sdpMid'],
        p['sdpMLineIndex'] == null
            ? 0
            : int.tryParse(p['sdpMLineIndex'].toString()) ?? 0,
      ));
      dlog('ice remote added ${iceDigest(p['candidate'])} '
          'mid=${p['sdpMid']}');
    } catch (e) {
      dlog('ice remote add failed: $e');
    }
  }

  Future<void> _cleanup() async {
    _callId = null;
    _pendingOfferSdp = null;
    _pendingIce.clear();
    _remoteIce.clear();
    _ringTimer?.cancel();
    _ringTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    await _stopRingback();
    await _closeTransport();
    // Cleanup races test/dispose teardowns across an async gap: never
    // assign state on a dead provider (Riverpod throws).
    if (!ref.mounted) return;
    state = null;
  }

  /// Close the local transport only: PC, streams, renderers, senders.
  /// Keeps state, the dry-ring offer, queued remote ICE and call ids — the
  /// displaced/switch paths manage those explicitly. Idempotent (§38).
  Future<void> _closeTransport() async {
    _remoteDescSet = false;
    _remoteVideoArrived = false;
    _stopQuality();
    _videoSender = null;
    if (_screen != null) {
      for (final t in _screen!.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await _screen!.dispose();
      } catch (_) {}
      _screen = null;
    }
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      await _local?.dispose();
    } catch (_) {}
    _local = null;
    // Video cameras serve one grabber on Windows; free our claim so the
    // next call (here or in another instance) can take the device.
    CameraLock.release();
    try {
      await _remoteStream?.dispose();
    } catch (_) {}
    _remoteStream = null;
    try {
      await _localR?.dispose();
    } catch (_) {}
    _localR = null;
    try {
      await _remoteR?.dispose();
    } catch (_) {}
    _remoteR = null;
  }
}

final callStateProvider =
    NotifierProvider<CallState, ActiveCall?>(CallState.new);

/// Raw server codes must never reach the UI.
String friendlyCallError(Object e) {
  if (e is GrchatException) {
    return switch (e.code) {
      'USER_OFFLINE' => 'Пользователь не в сети',
      'NOT_FOUND' => 'Пользователь не найден',
      'NOT_IN_CALL' => 'Звонок уже завершён',
      'ALREADY_IN_CALL' => 'Вы уже сейчас в звонке',
      _ => 'Не вышло позвонить',
    };
  }
  return 'Не вышло позвонить';
}

/// One-shot UI notices ("Нет ответа", "Пропущенный звонок от X").
/// Overlay shows each via SnackBar and clears it.
class CallNotice extends Notifier<String?> {
  @override
  String? build() => null;

  void show(String text) => state = text;
  void clear() => state = null;
}

final callNoticeProvider =
    NotifierProvider<CallNotice, String?>(CallNotice.new);

/// Redial offer after an unanswered outgoing call (§94): the ringing call
/// ended (local timeout or peer decline) and the user gets the reason plus a
/// "Позвонить снова" action instead of a dead-end toast.
class CallRedial {
  const CallRedial(
      {required this.reason,
      required this.peerNick,
      required this.dmId,
      required this.video});
  final String reason;
  final String? peerNick;
  final String? dmId;
  final bool video;
}

class CallRedialStack extends Notifier<CallRedial?> {
  @override
  CallRedial? build() => null;

  void offer(CallRedial r) => state = r;
  void clear() => state = null;
}

final callRedialProvider =
    NotifierProvider<CallRedialStack, CallRedial?>(CallRedialStack.new);
