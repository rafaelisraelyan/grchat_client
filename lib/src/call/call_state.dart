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
import 'camera_notice.dart';
import 'quality_tier.dart';
import '../media/media_prefs.dart';
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
    this.ringCameraOn = true,
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

  /// Incoming-video camera INTENT at accept time (ringing only): what the
  /// user chose on the incoming card. Default follows the dial; the toggle
  /// never captures the device — the accept gate does. After accept the
  /// intent loses meaning ([video] + real tracks take over).
  final bool ringCameraOn;

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
    bool? video,
    bool? ringCameraOn,
  }) => ActiveCall(
    callId: callId,
    peerNick: peerNick,
    // Mutable: the camera can be enabled midway through a call
    // (renegotiation, voice-channel behavior).
    video: video ?? this.video,
    outgoing: outgoing,
    phase: phase ?? this.phase,
    muted: muted ?? this.muted,
    cameraOff: cameraOff ?? this.cameraOff,
    sharingScreen: sharingScreen ?? this.sharingScreen,
    remoteVideo: remoteVideo ?? this.remoteVideo,
    linkDown: linkDown ?? this.linkDown,
    minimized: minimized ?? this.minimized,
    ringCameraOn: ringCameraOn ?? this.ringCameraOn,
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
}) => ActiveCall(
  callId: callId,
  peerNick: peerNick,
  video: video,
  outgoing: false,
  remoteVideo: remoteVideoArrived,
  phase: CallPhase.ringing,
);

class CallState extends Notifier<ActiveCall?> {
  RTCPeerConnection? _pc;
  MediaStream? _local;
  RTCVideoRenderer? _localR;
  RTCVideoRenderer? _remoteR;
  RTCRtpSender? _videoSender;

  /// The m-line HOLDER created when a video call starts without a local
  /// capture (§call-type): a sendrecv video transceiver with no track. It
  /// is negotiated recvonly, so a camera attached to it needs one
  /// renegotiation before frames really reach the peer
  /// (see [_senderCanSendVideo]).
  RTCRtpTransceiver? _videoTransceiver;
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

  /// Video-only capture from a mid-call camera enable: the call started
  /// as a voice channel and the video track joined later, in a separate
  /// getUserMedia. Disposed with the transport like [_local].
  MediaStream? _localVideo;

  /// Mid-call renegotiation (late camera enable) is serialized: one
  /// offer/answer round at a time, the progress signalled by [_renegoWait].
  bool _renegoLock = false;
  Completer<bool>? _renegoWait;

  /// A remote video track has arrived at least once. Tracked separately from
  /// [ActiveCall.remoteVideo] because _prepareIncoming rebuilds the ringing
  /// state from scratch *after* setRemoteDescription, and onTrack has already
  /// fired by then - a fresh object would silently drop the flag and leave
  /// the callee staring at "Подключение видео…" forever.
  bool _remoteVideoArrived = false;

  /// Inbound-counter watchdog for the remote camera (§remote-mute).
  final _remoteVideoWatch = RemoteVideoWatch();

  /// Sanitizes a capture-side fps reading before it may become a tier ceiling
  /// (§capture-fps). A black-hole virtual camera (AMD Privacy View, measured
  /// 2026-10-14) reports ~465 fps of synthetic black — such a reading would
  /// floor the tier at a nonsense ceiling and hide every real degradation, so
  /// anything above [kMaxCameraFps] (the owner's hard 60 fps ceiling) becomes
  /// UNKNOWN (-1) and only resets the learner. A plain 0 ("no reading this
  /// tick") is passed through: the learner's own two-tick confirmation
  /// decides when the cap is released, and a single missing sample must not
  /// drop it. [maxSane] defaults to [kMaxCameraFps] (spelled as a literal
  /// because a const int can only be a const double default). Pure so the
  /// rule is testable.
  static double sanitizeObservedFps(
    double raw, {
    double maxSane = 60,
  }) {
    if (raw < 0 || raw > maxSane) return -1;
    return raw;
  }

  /// Call tones (P2P only): RU ringback while dialling, a short blip when
  /// a call ends or an outgoing attempt fails. Delegated to [CallTones]:
  /// audioplayers touches a platform channel whose headless init cannot be
  /// try/caught, so engine code never constructs AudioPlayer directly.
  Future<void> _startRingback() => ref.read(callTonesProvider).startRingback();

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
    _pushSub ??= ref.read(connectionProvider).pushes.listen(_onPush);
  }

  Future<Map<String, dynamic>> _rtcConfig() async {
    final servers = <Map<String, dynamic>>[
      {
        'urls': ['stun:stun.l.google.com:19302'],
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
      dlog(
        'ice local candidate ${iceDigest(c.candidate)} '
        'sdpMid=${c.sdpMid} mline=${c.sdpMLineIndex}',
      );
      final payload = {
        'candidate': c.candidate!,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex?.toString(),
      };
      if (_callId == null) {
        _pendingIce.add(payload);
      } else {
        ref
            .read(callApiProvider)
            .ice(
              callId: _callId!,
              candidate: payload['candidate']!,
              sdpMid: payload['sdpMid'],
              sdpMLineIndex: payload['sdpMLineIndex'],
            )
            .catchError((_) {});
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
    dlog(
      'onTrack kind=${track.kind} id=${track.id} '
      'enabled=${track.enabled} streams=${ev.streams.length}',
    );
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
      final known = remote.getTracks().any((t) => t.id == track.id);
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
        // The video track can ride its OWN msid (late camera enable binds
        // a fresh gUM stream, the SDP then carries that id), so the renderer
        // must point at the stream that actually holds the video track —
        // the old audio stream's native video_tracks() stays empty and the
        // texture stays black even while the engine decodes frames.
        try {
          final vs = ev.streams.isNotEmpty ? ev.streams.first : remote;
          _remoteR?.srcObject = vs;
          dlog(
            'remote video rebind to stream '
            '${vs.id} (late track ${track.id})',
          );
        } catch (e) {
          dlog('remote video rebind failed: $e');
        }
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
  int _cameraFpsCap = 0;

  /// Guard against double camera/mic switch taps (one native open at a
  /// time; declines land as notices, not silent drops).
  bool _switchBusy = false;

  /// The low-fps banner shows ONCE per call (§switch-banner): reset at
  /// quality start, set when the notice fires.
  bool _capNoticeShownForCall = false;

  /// No learning before this moment (stats may lag a source switch).
  DateTime _learnHoldUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Learning reset core for the mid-call device switch (§switch-camera):
  /// the fps ceiling (plus its UI chip), the learned capture height and
  /// the tier hold all start over for the new capture. Public for tests;
  /// [switchCamera] routes through it.
  void resetCaptureLearning() {
    _fpsCap.reset();
    if (_cameraFpsCap != 0) _cameraFpsCap = 0;
    _captureHeight = 0;
    _holdLearning();
  }

  @visibleForTesting
  int get cameraFpsCapValue => _cameraFpsCap;

  @visibleForTesting
  int get captureHeightValue => _captureHeight;

  /// Test hook: pre-teach the learning fields (the reset contract must be
  /// observable without a live camera).
  @visibleForTesting
  void debugLearnCapture({required int capFps, required int height}) {
    _cameraFpsCap = capFps;
    _captureHeight = height;
  }

  /// Camera fps ceiling (§capture-fps): learned from InputFramesPerSecond;
  /// 0 = the tier fps stands. Floors every tier's maxFramerate and surfaces
  /// in the media-area chip: a 15 fps camera keeps the resolution ladder
  /// but nothing can make motion smoother - visible, not implied.
  final FpsCapLearn _fpsCap = FpsCapLearn();

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
    _capNoticeShownForCall = false;
    _applyTier();
    _qualityTimer ??= Timer.periodic(_qualityPeriod, (_) => _qualityTick());
  }

  void _stopQuality() {
    _qualityTimer?.cancel();
    _qualityTimer = null;
    _quality = null;
    _qualityBusy = false;
    _qualityStallLogged = false;
    ref.read(cameraCapBannerProvider.notifier).hide();
    _audioSender = null;
    _captureHeight = 0;
    _fpsCap.reset();
    if (_cameraFpsCap != 0) {
      _cameraFpsCap = 0;
    }
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
      // Camera fps ceiling (§capture-fps): the capture-side fps is the one
      // truth about a hardware/driver ceiling - the encoder OUTPUT fps can
      // dip under bandwidth adaptation (limitation != none), the capture
      // number cannot. Two stable ticks before a commit: a startup
      // transient never floors the tier. NOTE: qualityLimitationReason is
      // the STRING 'none' when free - 2026-10-13 00:51 live call proved the
      // null-only check silently disabled the whole learning.
      final noLimit =
          m.limitation == null ||
          m.limitation!.isEmpty ||
          m.limitation == 'none';
      final observedFps = sanitizeObservedFps(
        m.inputFps > 0
            ? m.inputFps
            : (noLimit ? (m.framesPerSecond ?? 0) : -1.0),
      );
      final capBefore = _fpsCap.cap;
      if (observedFps >= 0) {
        _fpsCap.update(observedFps, tierFps: q.tier.fps);
      } else {
        _fpsCap.reset();
      }
      if (_fpsCap.cap != capBefore) {
        // Sticky floor: flicker within ±1 fps of the committed value (the
        // 00:59 live call alternated 10<->11 every few ticks) does not
        // churn the tier apply or flap the UI chip - only a real move
        // (>1 fps) rewrites the floor.
        final raw = _fpsCap.cap;
        if ((raw - _cameraFpsCap).abs() <= 1) {
          _fpsCap.cap = _cameraFpsCap; // keep the learner on the sticky value
        } else {
          _cameraFpsCap = raw;
          dlog(
            _cameraFpsCap > 0
                ? 'camera fps cap: $_cameraFpsCap - tier fps ceiling floored at '
                      'the capture rate, resolution ladder still applies'
                : 'camera fps cap released (${q.tier.name} fps restored)',
          );
          await _applyTier();
          // Low-fps banner (§switch-banner): ONCE per call, local video
          // only, not during a share. The alternative-camera count picks
          // the text variant; pure decision, no UI coupling.
          if (_cameraFpsCap > 0 && !_capNoticeShownForCall) {
            final v = state;
            final videoOn = v?.video == true && v!.cameraOff == false;
            final alternatives = (await MediaPrefs.cameras()).length > 1;
            if (shouldShowCameraCapNotice(
              capFps: _cameraFpsCap,
              videoOn: videoOn,
              sharing: _screen != null,
              alreadyShown: _capNoticeShownForCall,
              hasOtherCameras: alternatives,
            )) {
              _capNoticeShownForCall = true;
              ref
                  .read(cameraCapBannerProvider.notifier)
                  .show(
                    CameraCapBanner(
                      capFps: _cameraFpsCap,
                      withSettingsButton: alternatives,
                    ),
                  );
            }
          }
        }
      }
      final changed = q.update(m, DateTime.now());
      if (changed != null) {
        dlog(
          'video tier -> $changed '
          '(avail=${m.availableOutKbps?.round()}kbps '
          'rtt=${m.rttMs?.round()}ms loss=${m.lossPct?.toStringAsFixed(1)}% '
          'limit=${m.limitation})',
        );
        await _applyTier();
      }
      // One diagnostics line per tick (the numbers round to integers; a
      // missing value prints as '-').
      String n(Object? v) =>
          v is double ? v.round().toString() : (v?.toString() ?? '-');
      final frameW = m.frameWidth?.round(), frameH = m.frameHeight?.round();
      dlog(
        'quality: tier=${q.tier.name} '
        'avail=${n(m.availableOutKbps)} sent=${n(q.sentKbps)} '
        'fps=${n(m.framesPerSecond)} '
        'frame=${(frameW != null && frameH != null && frameW > 0 && frameH > 0) ? '${frameW}x$frameH' : '-'} '
        'rtt=${n(m.rttMs)} '
        'loss=${m.lossPct?.toStringAsFixed(1) ?? '-'}% '
        'limit=${m.limitation ?? '-'}',
      );
      if (q.videoStalled && !_qualityStallLogged) {
        _qualityStallLogged = true;
        dlog('quality: no outgoing video (bytes frozen) — tier control paused');
      } else if (!q.videoStalled) {
        _qualityStallLogged = false;
      }
      // Remote camera off (§remote-mute): the peer's camera being off (or a
      // dead link) freezes OUR inbound counters while the renderer keeps the
      // last frame — a frozen black tile that looks like a live screen. No
      // mute event exists on this plugin build, so the counters decide: flip
      // remoteVideo off to show the avatar again, and back on when frames
      // resume.
      if (_remoteVideoWatch.update(
        inboundBytes: m.inboundVideoBytes,
        expectVideo: state?.remoteVideo == true,
      )) {
        final gone = _remoteVideoWatch.gone;
        state = state?.copyWith(remoteVideo: !gone);
        dlog(
          gone
              ? 'remote video gone: no inbound video for '
                  '${_remoteVideoWatch.staleTicks} ticks - showing the avatar'
              : 'remote video back: inbound video flowing again',
        );
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
      final tp = tierParams(
        q.tier,
        captureHeight: sharing ? 0 : _captureHeight,
        captureFps: sharing ? 0 : _cameraFpsCap.toDouble(),
      );
      for (final e in enc) {
        e.maxBitrate = tp.maxBitrate;
        e.maxFramerate = tp.maxFramerate;
        e.scaleResolutionDownBy = tp.scaleDownBy;
      }
      p.degradationPreference = sharing
          ? RTCDegradationPreference.MAINTAIN_RESOLUTION
          : RTCDegradationPreference.BALANCED;
      final ok = await sender.setParameters(p);
      dlog(
        'video tier ${q.tier} scale=${tp.scaleDownBy.toStringAsFixed(2)} '
        'fps<=${tp.maxFramerate} camfps=${_cameraFpsCap > 0 ? _cameraFpsCap : '-'} '
        'applied=$ok',
      );
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
  /// asks candidate profiles one by one, reads the REAL result (frames via
  /// a temporary renderer), keeps the best capture and frees the rest. The
  /// winner is recommended to the tier logic as the device's actual mode
  /// (capture height from the driver, not guessed).
  Future<MediaStream> _openLocalMedia(bool video) async {
    // Echo cancellation, noise suppression and auto gain stay on; the
    // high-pass filter removes desk/fan rumble that costs bits and clarity.
    final audio = await _micConstraints();
    if (!video) {
      return navigator.mediaDevices.getUserMedia({
        'audio': audio,
        'video': false,
      });
    }
    // Call start: microphone and camera ride one stream. A null ladder
    // result (device busy in another instance, or nothing delivered
    // frames) does NOT downgrade the CALL to audio: the call type is the
    // one the user dialled (§call-type) and the m-line is kept by a
    // placeholder transceiver in [_addLocal] - the camera attaches later
    // through replaceTrack.
    final s = await _captureCamera(audio);
    if (s == null) {
      dlog('camera unavailable at dial, keeping the video call');
      _captureMissingAtStart = true;
      return navigator.mediaDevices.getUserMedia({
        'audio': audio,
        'video': false,
      });
    }
    if (s.getAudioTracks().isNotEmpty) return s;
    // The camera is fine but the microphone did not come along (a device
    // error on the audio side). Throwing the capture away here would
    // downgrade a WORKING camera for a broken mic - open the mic alone
    // and adopt the verified video track into that stream.
    dlog('microphone missing from the capture, opening it alone');
    try {
      final a = await navigator.mediaDevices.getUserMedia({
        'audio': audio,
        'video': false,
      });
      for (final t in s.getVideoTracks()) {
        await a.addTrack(t);
      }
      await s.dispose();
      return a;
    } catch (e) {
      dlog('microphone open failed too: $e');
      for (final t in s.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      await s.dispose();
      return navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
    }
  }

  /// The user-picked (or default-resolved) microphone. A stale pick (e.g.
  /// NVIDIA Broadcast was closed) falls back to the platform default
  /// silently: an exact-miss must not take the whole call down.
  ///
  /// Plugin grammar (§discoveries 2026-10-13): the AUDIO input device is
  /// matched by the legacy optional/[{sourceId}] values of
  /// SanitizeDeviceIdFromAudioBuffers; `deviceId` (plain-string) only
  /// selects the PLAYBACK (speaker) output, and a `{'exact': N}` map is
  /// ignored everywhere - before this fix the pick was cosmetic and the
  /// capture always opened RecordingDevice(0).
  Future<Map<String, dynamic>> _micConstraints({String? overrideMicId}) async {
    final audio = <String, dynamic>{
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
      'highpassFilter': true,
    };
    final micId = overrideMicId ?? await MediaPrefs.resolveMicId();
    if (micId != null && micId.isNotEmpty) {
      audio['optional'] = [
        {'sourceId': micId},
      ];
    }
    return audio;
  }

  /// The device the plugin ACTUALLY opened at the last successful camera
  /// capture (getSettings().deviceId - not an echo). The camera switch
  /// skips itself when the requested device is already live.
  String _openedCameraId = '';

  /// The call was STARTED as a video call but no local capture could be
  /// opened (device busy / wedged driver). The m-line survives as a
  /// placeholder (§call-type), so the UI must show the camera-off state
  /// and invite a late enable instead of pretending the call is audio.
  bool _captureMissingAtStart = false;

  /// Stops every track, disposes the stream and logs the release. Video
  /// tracks log as `camera released: label=...`, audio-only streams as
  /// `microphone released: label=...` - so a swap shows perfect
  /// opened/released pairing in the desktop log (§camera-release). The
  /// [what] tag names the path; `silent` suppresses the log line (used
  /// when the track was already released+logged individually in the same
  /// change, keeping the log paired 1:1 with real grabs).
  Future<void> _releaseStream(
    MediaStream? s,
    String what, {
    bool silent = false,
  }) async {
    if (s == null) return;
    final video = s.getVideoTracks();
    final audio = s.getAudioTracks();
    final lab = video.isNotEmpty
        ? video.first.label
        : (audio.isNotEmpty ? audio.first.label : '-');
    final kindTag = video.isNotEmpty ? 'camera' : 'microphone';
    for (final t in s.getTracks()) {
      try {
        await t.stop();
      } catch (_) {}
    }
    try {
      await s.dispose();
    } catch (_) {}
    if (!silent) {
      dlog('$kindTag released: label=$lab ($what)');
    }
  }

  /// Open the camera ONLY (no audio) through the probe ladder. Used by
  /// [_openLocalMedia] with the mic constraints attached, and alone for a
  /// late camera enable mid-call ([enableCamera]) / the mid-call device
  /// switch ([switchCamera]). Returns null when the camera cannot deliver:
  /// another grchat instance owns it (CameraLock), every profile is
  /// refused, the last-resort open throws, or - with a [deviceId] override
  /// (device switch) - the plugin opened a DIFFERENT device than asked
  /// (never trade a live call onto an unplanned camera), or the override
  /// had no VERIFIED profile at all (no blind fallback for switches).
  /// `keepLockOnFail` keeps the CameraLock on total failure - the switch
  /// callers already own it for the whole call; releasing it mid-call
  /// would let the second instance steal the device. Callers decide the
  /// fallback otherwise; the lock is held for the whole call on success.
  Future<MediaStream?> _captureCamera(
    Map<String, dynamic>? audio, {
    String? deviceId,
    bool keepLockOnFail = false,
    bool allowOtherDevices = false,
  }) async {
    // Target: an explicit override (device switch) wins; otherwise the
    // preference chain - stale picks quietly reset inside resolveCameraId,
    // 'auto' = the first PHYSICAL camera (virtual devices are not the
    // default any more).
    final camId = deviceId ?? await MediaPrefs.resolveCameraId();
    // [allowOtherDevices] is the «Автоматически» choice: the user named no
    // device, so landing on another working one is the POINT of the pick -
    // unlike a named device, which must never be traded for another one.
    final explicitTarget =
        deviceId != null && deviceId.isNotEmpty && !allowOtherDevices;

    // Cross-process arbitration: another grchat instance may already own
    // the camera. Rather than both sides "opening" the SAME device and
    // getting zero frames, we skip the resolved camera (the one that
    // instance almost certainly holds) and let the walk below try the
    // others - two windows can hold two different cameras. A NAMED device
    // keeps its no-substitution contract: the caller decides the fallback.
    final lockFree = CameraLock.acquire();
    if (!lockFree) {
      dlog('camera busy (another grchat instance owns it) - trying other devices');
    }

    if (lockFree || allowOtherDevices) {
      final first = await _tryCameraDevice(
        camId,
        audio,
        expect: explicitTarget ? deviceId : null,
      );
      if (first.stream != null) {
        _applyCaptureHeight(first.height);
        return first.stream;
      }
    }

    // A device switch MUST NOT land on another camera or on the blind
    // fallback: its job is a VERIFIED capture of the named device - all
    // candidates refused means the device is unavailable (or wedged by
    // another holder, e.g. the NVIDIA Broadcast app holds the physical
    // camera), and the old capture stays live (§switch-camera failure
    // contract).
    if (explicitTarget) {
      if (!lockFree) {
        dlog(
          'camera switch: $deviceId not tried - another grchat instance '
          'owns the camera right now',
        );
      } else if (keepLockOnFail) {
        dlog(
          'camera switch: no verified profile for $deviceId - switch '
          'aborted, the lock stays with this instance',
        );
      } else {
        CameraLock.release();
        dlog('camera switch: no verified profile for $deviceId');
      }
      return null;
    }

    // CALL START ONLY (§dial-camera-walk): the resolved camera delivered
    // nothing - a wedged driver, a foreign holder, or a dead default. A
    // video call must not die on that: walk the other cameras and take the
    // first that REALLY delivers frames, then persist it, so the next call
    // starts on a working device instead of rediscovering the same dead
    // one.
    for (final alt in await _otherCameras(camId)) {
      dlog('camera walk: trying ${alt.label}');
      final r = await _tryCameraDevice(alt.id, audio, quick: true);
      if (r.stream != null) {
        dlog('camera walk: using ${alt.label}');
        await MediaPrefs.setCameraDeviceId(alt.id);
        _applyCaptureHeight(r.height);
        return r.stream;
      }
    }

    // Last resort: ask with NO sourceId at all. Sometimes a device that
    // refuses a targeted `optional/[{sourceId}]` open happily as the
    // platform default, so the ask stays classic (an ask with the same
    // mandatory min that starved the ladder would starve here too). It is
    // PROBED like any other candidate - a capture without frames is a
    // black video track, worse than no track (§call-type keeps the m-line
    // anyway).
    dlog('camera: no profile delivered frames, falling back');
    try {
      final constraints = <String, dynamic>{
        'video': _videoProfile(null, 1280, 720, 30),
      };
      if (audio != null) constraints['audio'] = audio;
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      final vtrack = stream.getVideoTracks().first;
      final st = vtrack.getSettings();
      final opened = (st['deviceId'] ?? '').toString();
      if (stream.getVideoTracks().isEmpty) {
        await _releaseStream(stream, 'fallback without a video track');
        if (!keepLockOnFail) CameraLock.release();
        dlog('camera fallback: no video track in the default open');
        return null;
      }
      final probe = await _firstFrameProbe(stream);
      if (!probe.frameArrived) {
        await _releaseStream(stream, 'fallback delivered no frames');
        if (!keepLockOnFail) CameraLock.release();
        dlog('camera fallback: open ok, no frames');
        return null;
      }
      _openedCameraId = opened;
      dlog(
        'camera opened: label=${vtrack.label}, requested=1280x720@30, '
        'source=fallback, device=$opened, '
        'real=${probe.width}x${probe.height}',
      );
      _applyCaptureHeight(probe.height);
      return stream;
    } catch (e) {
      if (!keepLockOnFail) {
        CameraLock.release();
      }
      dlog('camera fallback failed: $e');
      return null;
    }
  }

  /// The plugin's video constraint for ONE device at one profile.
  ///
  /// Grammar fact (flutter_media_stream.cc:143-158): the video device is
  /// matched ONLY through the legacy `optional: [{sourceId}]` values; a
  /// top-level `deviceId` ({ideal}/{exact}/plain) is not read for VIDEO and
  /// silently falls back to device index 0. Rate-wise every spelling ended
  /// up in the same single integer in native Create (vs 02:13
  /// mandatory-minFrame and 02:19 ideal control calls - both led to honest
  /// 1080p60 on OBS VC), so the ladder asks `ideal`.
  static Map<String, dynamic> _videoProfile(
    String? camId,
    int w,
    int h,
    int fps,
  ) {
    return <String, dynamic>{
      'width': {'ideal': w},
      'height': {'ideal': h},
      'frameRate': {'ideal': fps},
      if (camId != null && camId.isNotEmpty)
        'optional': [
          {'sourceId': camId},
        ],
    };
  }

  /// Cameras to try after the resolved one delivered nothing: the pure
  /// rescue order lives in [MediaPrefs.walkOrderFrom] (physical first,
  /// capped); this only feeds it the enumerated devices.
  Future<List<({String id, String label})>> _otherCameras(String? used) async {
    final cams = await MediaPrefs.cameras();
    return MediaPrefs.walkOrderFrom(
      cams.map((d) => (id: d.deviceId, label: d.label)).toList(),
      used,
    );
  }

  /// Ladder control after one candidate was rejected. Frames that arrived
  /// but stayed below the ask are a PROFILE problem - the next profile still
  /// gets its turn; an open with no frames at all is a DEVICE-level answer
  /// (wedged driver, a foreign holder, an unplugged camera), and repeating
  /// the sweep on it only burns dial time (each dead open costs the full
  /// probe timeout). Pure so the rule is testable.
  static bool ladderShouldStop({
    required bool frameArrived,
    required int frameless,
    required int budget,
  }) =>
      !frameArrived && frameless >= budget;

  /// Compact device fingerprint for the probe log lines. Windows ids are
  /// 90-character USB paths (`\\?\usb#vid_...`) and several cameras can be
  /// probed in one call, so a line without the device is unreadable when
  /// diagnosing which one delivers nothing. Pure so it is testable.
  static String shortDevice(String? id) {
    final s = (id ?? '').trim();
    if (s.isEmpty) return 'default';
    if (s.length <= 44) return s;
    return '${s.substring(0, 26)}…${s.substring(s.length - 10)}';
  }

  /// Full profile ladder - the honest capture-height sweep (§quality).
  static const _ladderFull = <(int, int, int)>[
    (1920, 1080, 60),
    (1920, 1080, 30),
    (1280, 720, 60),
    (1280, 720, 30),
    (640, 480, 30),
  ];

  /// Walk ladder: top profile plus the classic 720p30. A rescue attempt
  /// needs a working capture, not a perfect profile sweep - the tier logic
  /// scales to whatever the device really delivers.
  static const _ladderQuick = <(int, int, int)>[(1920, 1080, 60), (1280, 720, 30)];

  /// TRUE capture height for the tier scale: verified by actual frames.
  /// Set unconditionally - a device change may LOWER the capture and the
  /// scale-down must follow the new device, not cling to the old.
  void _applyCaptureHeight(int height) {
    if (height > 0 && height != _captureHeight) {
      _captureHeight = height;
      dlog('capture height from device: ${_captureHeight}p');
    }
  }

  /// One device through the probe ladder: profiles from high to low, each
  /// accepted only when frames really reach a renderer at close to the
  /// asked height (a half-delivered mode is skipped, the rest of the ladder
  /// still gets its turn). [expect] is the id a device switch demands: when
  /// the plugin opened another index the capture is refused and released -
  /// a live call never trades onto an unplanned camera. Returns the
  /// verified stream plus its real capture height (from frames, never from
  /// the ask).
  ///
  /// Frameless budget: an open that delivers NOTHING is a device-level
  /// answer (wedged driver, a foreign holder such as the NVIDIA Broadcast
  /// app, a cable-pulled camera), not a profile problem - hammering the
  /// remaining profiles of such a device only spends the dial time (each
  /// dead open costs the full 1.5 s probe). So the ladder gives up after a
  /// couple of frameless opens, while a device that DOES deliver keeps
  /// getting its full sweep. [quick] (walk rescue) uses the two-profile
  /// ladder and stops at the first frameless open.
  Future<({MediaStream? stream, int height})> _tryCameraDevice(
    String? camId,
    Map<String, dynamic>? audio, {
    String? expect,
    bool quick = false,
  }) async {
    final candidates = quick ? _ladderQuick : _ladderFull;
    final framelessBudget = quick ? 1 : 2;
    final dev = shortDevice(camId);
    var frameless = 0;
    for (final c in candidates) {
      MediaStream s;
      try {
        final constraints = <String, dynamic>{
          'video': _videoProfile(camId, c.$1, c.$2, c.$3),
        };
        if (audio != null) constraints['audio'] = audio;
        s = await navigator.mediaDevices.getUserMedia(constraints);
      } catch (e) {
        // The ask was refused outright: the mode does not exist at all.
        dlog('camera probe [$dev] ${c.$1}x${c.$2}@${c.$3} refused ($e)');
        continue;
      }
      // getSettings() on desktop echoes the REQUESTED constraints, not the
      // real device mode, and drivers sometimes open a mode they cannot
      // deliver (e.g. ask 1080p30, receive 720p). Accept a candidate only
      // when frames really reach a renderer AND the frame height is close
      // to the ask; a half-delivered mode is skipped so the ladder can try
      // the rest (640p60/30 etc).
      final probe = await _firstFrameProbe(s);
      if (probe.frameArrived && probe.height >= c.$2 * 0.8) {
        // HONEST device log (§lessons 2026-10-13): 'pick=' used to print
        // the USER'S REQUEST while the plugin silently opened device 0 -
        // that misread cost us a week of chasing the wrong cause. The
        // getSettings().deviceId on this plugin is NOT an echo: it is the
        // ACTUALLY opened device (the matched sourceId, or the device-0
        // fallback re-assigned inside the plugin before being echoed).
        // track.label on this plugin is the random track id, still in the
        // spec line for traceability.
        final st = s.getVideoTracks().first.getSettings();
        final opened = (st['deviceId'] ?? '').toString();
        final lab = s.getVideoTracks().first.label;
        final source = expect != null
            ? 'explicit'
            : (camId != null && camId.isNotEmpty ? 'walk' : 'auto');
        dlog(
          'camera opened: label=$lab, requested=${c.$1}x${c.$2}@${c.$3}, '
          'source=$source, device=$opened, real=${probe.width}x${probe.height}',
        );
        _openedCameraId = opened;
        if (expect != null && opened.isNotEmpty && opened != expect) {
          // A switch must not trade the live call onto an unplanned
          // camera: the plugin fell back to another index.
          dlog('camera switch refused: opened $opened != wanted $expect');
          await _releaseStream(s, 'switch target mismatch');
          return (stream: null, height: 0);
        }
        return (stream: s, height: probe.height);
      }
      if (probe.frameArrived) {
        // Frames, but below the ask: this device works, so the next
        // profile still gets its turn.
        frameless = 0;
        dlog(
          'camera probe [$dev] ${c.$1}x${c.$2}@${c.$3}: frames are '
          '${probe.width}x${probe.height}, below the ask — skipping',
        );
      } else {
        frameless++;
        dlog('camera probe [$dev] ${c.$1}x${c.$2}@${c.$3}: open ok, no frames');
      }
      // Rejected candidate: the grabber must REALLY stop (not just be
      // disposed) or the camera light stays on and other apps are locked
      // out (§camera-release).
      await _releaseStream(s, 'probe ${c.$1}x${c.$2}@${c.$3} rejected');
      if (ladderShouldStop(
        frameArrived: false,
        frameless: frameless,
        budget: framelessBudget,
      )) {
        dlog(
          'camera [$dev]: no frames from this device ($frameless opens) - '
          'device-level failure, not a profile one',
        );
        break;
      }
    }
    return (stream: null, height: 0);
  }

  /// Attaches a temporary renderer and waits for the first frame: the only
  /// trustworthy proof that the camera actually delivers this profile.
  Future<({bool frameArrived, int width, int height})> _firstFrameProbe(
    MediaStream stream,
  ) async {
    final gotOne = Completer<int>();
    RTCVideoRenderer? r;
    try {
      r = RTCVideoRenderer();
      r.onFirstFrameRendered = () {
        if (!gotOne.isCompleted) gotOne.complete(1);
      };
      await r.initialize();
      r.srcObject = stream;
      final timer = Timer(const Duration(milliseconds: 1500), () {
        if (!gotOne.isCompleted) gotOne.complete(0);
      });
      final v = await gotOne.future;
      timer.cancel();
      var h = 0;
      var w = 0;
      if (v == 1) {
        for (var i = 0; i < 25 && h == 0; i++) {
          await Future.delayed(const Duration(milliseconds: 40));
          w = r.videoWidth;
          h = r.videoHeight;
        }
      }
      return (frameArrived: v == 1, width: w, height: h);
    } catch (e) {
      dlog('camera frame probe failed: $e');
      return (frameArrived: false, width: 0, height: 0);
    } finally {
      try {
        await r?.dispose();
      } catch (_) {}
    }
  }

  Future<void> _addLocal(RTCPeerConnection pc, bool video) async {
    _local = await _openLocalMedia(video);
    final tracks = _local!.getTracks();
    dlog(
      'getUserMedia audio=${_local!.getAudioTracks().length} '
      'video=${_local!.getVideoTracks().length}',
    );
    for (final t in tracks) {
      dlog('local track kind=${t.kind} id=${t.id} enabled=${t.enabled}');
      final sender = await pc.addTrack(t, _local!);
      if (t.kind == 'video') _videoSender = sender;
      if (t.kind == 'audio') _audioSender = sender;
    }
    // §call-type (2026-10-13): the peer classifies the incoming call by the
    // offer SDP (`sdp.contains('m=video')` in _prepareIncoming). A video
    // dial whose camera could not be opened produced an audio-only offer,
    // so the callee's card said «Входящий аудиозвонок» for a call the user
    // had placed with video. A sendrecv video transceiver with NO track
    // keeps the m-line negotiated; the camera then lands on this very
    // sender through replaceTrack (no renegotiation, same path as the
    // late enable). In an ANSWER this is legal only when the peer's offer
    // really had a video m-line - an answer may not add media sections.
    if (video && _videoSender == null) {
      final peerOfferedVideo = _pendingOfferSdp?.contains('m=video') ?? true;
      if (peerOfferedVideo) {
        try {
          final t = await pc.addTransceiver(
            kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
            init: RTCRtpTransceiverInit(
              direction: TransceiverDirection.SendRecv,
            ),
          );
          _videoTransceiver = t;
          _videoSender = t.sender;
          dlog('video m-line kept without a local camera (sendrecv holder)');
        } catch (e) {
          dlog('video m-line holder failed: $e');
        }
      }
    }
    dlog('senders=${(await pc.getSenders()).length}');
    if (_captureMissingAtStart) {
      // The call keeps its video type (m-line holder above); the UI shows
      // the camera-off state and the camera button can attach a capture
      // mid-call. Say so once, in plain words.
      state = state?.copyWith(cameraOff: true);
      _notice('Камера сейчас занята — включите её во время звонка');
    }
    if (video) {
      _localR = RTCVideoRenderer();
      await _localR!.initialize();
      _localR!.srcObject = _local;
    }
    _remoteR = RTCVideoRenderer();
    await _remoteR!.initialize();
  }

  Future<void> startCall({
    String? peerNick,
    String? dmId,
    required bool video,
  }) async {
    if (state != null) return;
    // A pending redial belongs to the previous attempt.
    ref.read(callRedialProvider.notifier).clear();
    final api = ref.read(callApiProvider);
    final name = peerNick ?? 'Группа';
    state = ActiveCall(
      callId: '',
      peerNick: name,
      video: video,
      outgoing: true,
      phase: CallPhase.ringing,
    );
    // Dialling feedback starts with the ring, not with the network.
    unawaited(_startRingback());
    try {
      _pc = await _newPc('');
      await _addLocal(_pc!, video);
      final rawOffer = await _pc!.createOffer({});
      final offer = RTCSessionDescription(
        tuneOpusSdp(rawOffer.sdp ?? ''),
        rawOffer.type,
      );
      await _pc!.setLocalDescription(offer);
      final sdp = (await _pc!.getLocalDescription())?.sdp ?? '';
      dlog('offer ${SdpSummary.parse(sdp)}');
      final callId = await api.offer(peerNick: peerNick, dmId: dmId, sdp: sdp);
      _callId = callId;
      state = state?.copyWith();
      for (final p in _pendingIce) {
        api
            .ice(
              callId: callId,
              candidate: p['candidate']!,
              sdpMid: p['sdpMid'],
              sdpMLineIndex: p['sdpMLineIndex'],
            )
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
          phase: CallPhase.ringing,
        );
        // Unanswered outgoing: stop ringing before the server sweep (60s).
        // Offer redial (§94) instead of a dead-end toast.
        _armUnansweredTimeout(
          callId: callId,
          peerNick: peerNick,
          dmId: dmId,
          video: video,
        );
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
  void _armUnansweredTimeout({
    required String callId,
    String? peerNick,
    String? dmId,
    required bool video,
  }) {
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 50), () async {
      final c = state;
      if (c == null || c.callId != callId || c.phase != CallPhase.ringing) {
        return;
      }
      ref
          .read(callRedialProvider.notifier)
          .offer(
            CallRedial(
              reason: 'Нет ответа',
              peerNick: peerNick,
              dmId: dmId,
              video: video,
            ),
          );
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
        // The ring card camera toggle decides whether OUR camera joins:
        // off = answer a video-capable session without local capture
        // (m=video stays negotiated, the later enable reuses it).
        _pc = await _newPc(cur.callId);
        await _addLocal(_pc!, cur.video && cur.ringCameraOn);
        dlog('offer ${SdpSummary.parse(_pendingOfferSdp ?? '')}');
        await _pc!.setRemoteDescription(
          RTCSessionDescription(_pendingOfferSdp ?? '', 'offer'),
        );
        _remoteDescSet = true;
        await _flushRemoteIce();
        if (_remoteVideoArrived) {
          state = state?.copyWith(remoteVideo: true);
        }
      }
      final rawAnswer = await _pc!.createAnswer({});
      final answer = RTCSessionDescription(
        tuneOpusSdp(rawAnswer.sdp ?? ''),
        rawAnswer.type,
      );
      await _pc!.setLocalDescription(answer);
      final sdp = (await _pc!.getLocalDescription())?.sdp ?? '';
      dlog('answer ${SdpSummary.parse(sdp)}');
      await api.answer(callId: cur.callId, accept: true, sdp: sdp);
      _ringTimer?.cancel();
      // Patch the live state instead of writing back the pre-await snapshot:
      // onTrack may have delivered a remote video track meanwhile.
      // §14/§16: an accepted-with-camera-OFF VIDEO call shows its active
      // camera control OFF from the first frame — no flash grey→red. The
      // m=video m-line stays negotiated (§17): enabling later reuses it.
      state = state?.copyWith(
        phase: CallPhase.active,
        // A start without a usable capture keeps the camera-off state
        // (§call-type) even when the ring camera toggle said «on».
        cameraOff: _captureMissingAtStart || (cur.video && !cur.ringCameraOn),
      );
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
          video: disp.video,
        );
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

  /// All camera tracks across the call-start stream ([_local]) and the
  /// late-enabled capture ([_localVideo]), deduped by track id.
  List<MediaStreamTrack> _cameraTracks() {
    final byId = <String, MediaStreamTrack>{};
    for (final s in [_local, _localVideo]) {
      for (final t in s?.getVideoTracks() ?? const []) {
        byId[t.id] = t;
      }
    }
    return byId.values.toList();
  }

  /// Incoming ring card: flip the answer-with-camera intent. Never
  /// touches hardware (no capture before accept — privacy/indicator)
  /// and never accepts the call by itself.
  void toggleRingCamera() {
    final cur = state;
    if (cur == null || cur.outgoing || cur.phase != CallPhase.ringing) {
      return;
    }
    state = cur.copyWith(ringCameraOn: !cur.ringCameraOn);
  }

  /// Voice-channel behavior: turn the camera ON in an ongoing call. OFF is
  /// always cheap (track.enabled, no renegotiation); ON needs a real one —
  /// a fresh offer rides `call_renegotiate` over the same ICE transport,
  /// the peer replies with the same push, answer:true.
  Future<void> enableCamera() async {
    final cur = state;
    final pc = _pc;
    // The gate is REAL local capture, not the call's `video` flag: a
    // renegotiated peer video (we currently receive) also sets that flag,
    // and this side must still be able to turn its own camera on — the
    // later renegotiation adds the track to the same transceiver.
    if (cur == null ||
        pc == null ||
        _cameraTracks().isNotEmpty ||
        cur.phase != CallPhase.active ||
        _screen != null) {
      return;
    }
    if (_renegoLock) {
      dlog('enable camera: renegotiation already running, skipped');
      return;
    }
    _renegoLock = true;
    try {
      final cam = await _captureCamera(null);
      if (cam == null) {
        dlog('enable camera: device unavailable');
        _notice('Камера недоступна или занята другим приложением');
        return;
      }
      _localVideo = cam;
      final track = cam.getVideoTracks().first;
      // Adopt the track into the main local stream where toggles and the
      // screen-share switchback expect to find it.
      try {
        await _local?.addTrack(track);
      } catch (_) {
        // Some platforms refuse cross-stream adoption; [_cameraTracks]
        // covers the extra container either way.
      }
      final sender = await pc.addTrack(track, cam);
      _videoSender = sender;
      dlog('late camera enabled: track=${track.id}');
      // Bind the self-view FIRST: the `video: true` flip below rebuilds
      // the UI, and self-preview must exist only for a REAL capture
      // (never a placeholder box).
      _localR = RTCVideoRenderer();
      await _localR!.initialize();
      _localR!.srcObject = cam;
      state = state?.copyWith(video: true, cameraOff: false);
      // One offer/answer round on top of the live transport. The peer's
      // answer arrives as a push and completes the completer, so the
      // completer must exist BEFORE the offer goes out.
      _renegoWait = Completer<bool>();
      await _renegotiateVideo(cur.callId);
      _startQuality();
    } catch (e) {
      dlog('enable camera failed: $e');
      _notice('Не вышло включить камеру');
    } finally {
      _renegoWait = null;
      _renegoLock = false;
    }
  }

  /// One offer/answer round for a live call: the fresh offer rides
  /// `call_renegotiate` over the same ICE transport, the peer's answer
  /// comes back as the same push (answer:true). True when the peer
  /// confirmed the new m-line.
  Future<bool> _renegotiateVideo(String callId) async {
    final pc = _pc;
    if (pc == null) return false;
    try {
      final rawOffer = await pc.createOffer({});
      final offer = RTCSessionDescription(
        tuneOpusSdp(rawOffer.sdp ?? ''),
        rawOffer.type,
      );
      await pc.setLocalDescription(offer);
      final sdp = (await pc.getLocalDescription())?.sdp ?? '';
      dlog('renegotiate offer ${SdpSummary.parse(sdp)}');
      await ref.read(callApiProvider).renegotiate(callId: callId, sdp: sdp);
      final ok = await _renegoWait?.future.timeout(
            const Duration(seconds: 15),
            onTimeout: () => false,
          ) ??
          false;
      if (!ok) {
        dlog('renegotiation answer missing: peer stays video-less');
        // Keep our capture alive: the frames are just muted for the
        // peer until they answer a later renegotiation.
        _notice('Собеседник не подтвердил камеру');
      } else {
        dlog('renegotiation complete: video m-line live');
      }
      return ok;
    } catch (e) {
      dlog('renegotiate offer failed: $e');
      _notice('Не вышло включить камеру');
      return false;
    }
  }

  /// Does the negotiated video sender actually ALLOW sending? A transceiver
  /// created without a track (the §call-type m-line holder) is negotiated
  /// recvonly: `replaceTrack` would attach the capture and send NOTHING.
  /// A sender from addTrack (the normal call-start path) always may, so the
  /// check is only about the holder.
  Future<bool> _senderCanSendVideo() async {
    final t = _videoTransceiver;
    if (t == null) return true;
    try {
      final dir = await t.getCurrentDirection();
      dlog('video transceiver direction: $dir');
      return dir == TransceiverDirection.SendRecv ||
          dir == TransceiverDirection.SendOnly;
    } catch (e) {
      dlog('video transceiver direction unknown ($e) - assuming sendable');
      return true;
    }
  }

  /// Make sure the live m-line really sends after a capture was attached to
  /// the holder transceiver (§call-type) - one offer/answer round, guarded
  /// like [enableCamera] against a parallel renegotiation.
  Future<void> _ensureVideoSends() async {
    if (await _senderCanSendVideo()) return;
    final cur = state;
    if (cur == null || _renegoLock) return;
    _renegoLock = true;
    try {
      dlog('video m-line is recvonly, renegotiating to send');
      _renegoWait = Completer<bool>();
      await _renegotiateVideo(cur.callId);
    } finally {
      _renegoWait = null;
      _renegoLock = false;
    }
  }

  void toggleMute() {
    final cur = state;
    if (cur == null) return;
    final muted = !cur.muted;
    _local?.getAudioTracks().forEach((t) => t.enabled = !muted);
    state = cur.copyWith(muted: muted);
  }

  /// Camera toggle, now also the entry point for the late enable: a call
  /// without a local video track routes to [enableCamera] (renegotiation),
  /// a call with one stays on the cheap enabled flip.
  Future<void> toggleCamera() async {
    final cur = state;
    if (cur == null) return;
    if (_cameraTracks().isEmpty) {
      if (cur.phase != CallPhase.active || cur.sharingScreen) return;
      // Tracks released but the video m-line is alive (the camera was
      // turned off via the real release): re-enable is replaceTrack only.
      if (_videoSender != null) {
        await _enableAfterRelease();
        return;
      }
      await enableCamera();
      return;
    }
    final off = !cur.cameraOff;
    if (off) {
      // REAL release (§camera-release): the old enabled-flip kept the
      // capture grabber alive with the light on and locked the device
      // against other apps. The video m-line survives via replaceTrack
      // (null) - no renegotiation when the camera comes back.
      try {
        await _videoSender?.replaceTrack(null);
      } catch (_) {
        dlog('camera off: replaceTrack(null) failed, capture continues');
      }
      final olds = _cameraTracks();
      for (final t in olds) {
        // Native order quirk (§plugin-dispose-quirk): trackDispose runs
        // StopCapture ONLY while the track is still attached to a known
        // stream. Removing first detaches it and the dispose never finds
        // it - the grabber stays alive forever (2026-10-13 stuck camera;
        // OS ConsentStore showed no Stop event). Strict order: stop
        // FIRST, removeTrack after.
        try {
          await t.stop();
          dlog('camera released: label=${t.label} (camera off)');
        } catch (_) {}
        try {
          await _local?.removeTrack(t);
        } catch (_) {}
      }
      await _releaseStream(_localVideo, 'camera off', silent: true);
      _localVideo = null;
      if (_localR != null) _localR!.srcObject = null;
      // The capture is gone - its learning is stale (§switch-camera).
      resetCaptureLearning();
      // The device is really free: the second instance / another app can
      // take it while our camera is off; re-enabling re-acquires.
      CameraLock.release();
    }
    state = cur.copyWith(cameraOff: off);
  }

  /// Camera ON after a REAL release (§camera-release): the video m-line is
  /// still there (replaceTrack(null) kept the transceiver), so the fresh
  /// capture lands via replaceTrack with no renegotiation. If the second
  /// instance took the device while we were off, the open fails and the
  /// notice says so.
  Future<void> _enableAfterRelease() async {
    final cur = state;
    final pc = _pc;
    if (cur == null ||
        pc == null ||
        _videoSender == null ||
        cur.phase != CallPhase.active ||
        _screen != null) {
      return;
    }
    if (_switchBusy) return;
    _switchBusy = true;
    try {
      final cam = await _captureCamera(null);
      if (cam == null) {
        dlog('camera re-enable: device unavailable');
        _notice('Камера недоступна или занята другим приложением');
        return;
      }
      final track = cam.getVideoTracks().first;
      await _videoSender!.replaceTrack(track);
      try {
        await _local?.addTrack(track);
      } catch (_) {}
      await _localVideo?.dispose();
      _localVideo = cam;
      if (_localR != null) _localR!.srcObject = cam;
      state = state?.copyWith(video: true, cameraOff: false);
      resetCaptureLearning();
      await _applyTier();
      dlog('camera re-enabled: replaceTrack onto the live sender');
      // The holder m-line is negotiated recvonly (§call-type): attaching a
      // capture alone would send nothing, so raise it with one round.
      await _ensureVideoSends();
    } catch (e) {
      dlog('camera re-enable failed: $e');
      _notice('Не вышло включить камеру');
    } finally {
      _switchBusy = false;
    }
  }

  /// LIVE camera device change (settings dropdown during a call,
  /// §switch-camera). The user's confirmed contract: a device 'driver
  /// change' is a CYCLE - OFF, switch, ON. Some stacks (NVIDIA Broadcast
  /// holding the physical camera as its source) keep the old DirectShow
  /// pin busy while the call runs, so the old capture is FULLY released
  /// first, then the requested device opens through the same probe
  /// ladder, then the fresh track lands via replaceTrack (no
  /// renegotiation). CameraLock is owned continuously by this instance
  /// across the whole cycle: no release/reacquire window, no double lock.
  /// On a failed open the PREVIOUS device is re-opened automatically (the
  /// call keeps its camera); if that also fails, the call sits in the
  /// camera-off state and the user re-enables manually.
  ///
  /// [auto] marks the «Автоматически» choice (no named device): the walk
  /// over other cameras is allowed, because taking the best WORKING camera
  /// is exactly what that pick means. A named device never gets traded for
  /// another one.
  Future<bool> switchCamera(String deviceId, {bool auto = false}) async {
    final cur = state;
    if (cur == null ||
        cur.phase != CallPhase.active ||
        _screen != null ||
        _videoSender == null) {
      return false;
    }
    if (_switchBusy) return false;
    _switchBusy = true;
    // Skip only when the device is REALLY live (not camera-off: after the
    // real release the id in _openedCameraId is stale history).
    if (!cur.cameraOff && deviceId.isNotEmpty && deviceId == _openedCameraId) {
      dlog('camera switch skipped: device already active');
      _switchBusy = false;
      return true;
    }
    final stored = await MediaPrefs.cameraDeviceId();
    final previousDevice = _openedCameraId;
    final wasOff = cur.cameraOff;
    try {
      // 1) END the current capture (the OFF half of the cycle, §switch-camera):
      // the old DirectShow pin must be fully closed before the target
      // device opens.
      try {
        await _videoSender!.replaceTrack(null);
      } catch (e) {
        dlog('camera switch: replaceTrack(null) failed ($e), capture continues');
      }
      for (final t in _cameraTracks()) {
        // Native order quirk (§plugin-dispose-quirk): stop FIRST (this is
        // what runs StopCapture), removeTrack after.
        try {
          await t.stop();
          dlog('camera released: label=${t.label} (device switch off)');
        } catch (_) {}
        try {
          await _local?.removeTrack(t);
        } catch (_) {}
      }
      await _releaseStream(_localVideo, 'device switch off', silent: true);
      _localVideo = null;
      if (_localR != null) _localR!.srcObject = null;
      if (!wasOff) state = state?.copyWith(cameraOff: true);

      // 2) OPEN the requested device. The instance still owns CameraLock
      // (acquire is idempotent), so the second instance cannot interleave.
      final cam = await _captureCamera(
        null,
        deviceId: deviceId,
        keepLockOnFail: true,
        allowOtherDevices: auto,
      );
      if (cam == null) {
        throw StateError('device unavailable');
      }
      final newTrack = cam.getVideoTracks().first;
      if (wasOff) newTrack.enabled = false;

      // 3) BIND the fresh track (the ON half of the cycle).
      await _videoSender!.replaceTrack(newTrack);
      try {
        await _local?.addTrack(newTrack);
      } catch (_) {}
      _localVideo = cam;
      if (_localR != null) _localR!.srcObject = cam;
      resetCaptureLearning();
      await _applyTier();
      // The capture state follows the cycle: an off-camera selection
      // keeps the off intent (the new track starts disabled), a live
      // switch ends capturing again.
      state = state?.copyWith(video: true, cameraOff: wasOff);
      dlog('camera switched: sender now ${newTrack.id}');
      await _ensureVideoSends();
      return true;
    } catch (e) {
      dlog('camera switch failed: $e');
      // AUTO-RESTORE: re-open the previous device so the call keeps its
      // camera (§switch-camera). The lock is still ours.
      MediaStream? restored;
      if (previousDevice.isNotEmpty) {
        try {
          restored = await _captureCamera(
            null,
            deviceId: previousDevice,
            keepLockOnFail: true,
          );
        } catch (_) {}
      }
      if (restored != null) {
        final t = restored.getVideoTracks().first;
        if (wasOff) t.enabled = false;
        try {
          await _videoSender!.replaceTrack(t);
        } catch (_) {}
        try {
          await _local?.addTrack(t);
        } catch (_) {}
        _localVideo = restored;
        if (_localR != null) _localR!.srcObject = restored;
        state = state?.copyWith(video: true, cameraOff: wasOff);
        dlog('camera switch failed, previous device restored');
        await _ensureVideoSends();
      }
      await MediaPrefs.setCameraDeviceId(stored);
      _notice('Камера недоступна или занята другим приложением');
      return false;
    } finally {
      _switchBusy = false;
    }
  }

  /// LIVE microphone change: replaceTrack on the same audio sender
  /// (§switch-camera). The meeting keeps running; a failed open restores
  /// the stored pick.
  Future<bool> switchMicrophone(String deviceId) async {
    final cur = state;
    if (cur == null || cur.phase != CallPhase.active || _audioSender == null) {
      return false;
    }
    if (_switchBusy) return false;
    _switchBusy = true;
    final stored = await MediaPrefs.micDeviceId();
    try {
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': await _micConstraints(overrideMicId: deviceId),
        'video': false,
      });
      final newTrack = stream.getAudioTracks().first;
      final olds = _local?.getAudioTracks() ?? const [];
      await _audioSender!.replaceTrack(newTrack);
      for (final t in olds) {
        // Same native order quirk (§plugin-dispose-quirk): stop FIRST.
        try {
          await t.stop();
          dlog('microphone released: label=${t.label} (mic switch)');
        } catch (_) {}
        try {
          await _local?.removeTrack(t);
        } catch (_) {}
      }
      try {
        await _local?.addTrack(newTrack);
      } catch (_) {}
      dlog('microphone switched: sender now ${newTrack.id}');
      return true;
    } catch (e) {
      dlog('microphone switch failed: $e');
      _notice('Не вышло сменить микрофон');
      await MediaPrefs.setMicDeviceId(stored);
      return false;
    } finally {
      _switchBusy = false;
    }
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
        final stream = await navigator.mediaDevices.getDisplayMedia({
          'video': true,
        });
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
        await sender.replaceTrack(stream.getVideoTracks().first);
        _screen = stream;
        _localR?.srcObject = stream;
        dlog('screenshare sharing');
        state = state?.copyWith(sharingScreen: true);
        _holdLearning();
        _applyTier();
      } else {
        final cam = _cameraTracks();
        final sender = _videoSender;
        if (sender != null && cam.isNotEmpty) {
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
      final remoteAudio = _remoteStream?.getAudioTracks().isNotEmpty ?? false;
      final remoteVideo = _remoteStream?.getVideoTracks().isNotEmpty ?? false;
      return buildDebugSummary(
        platform: platformTag(),
        callId: cur.callId,
        role: cur.outgoing ? 'caller' : 'callee',
        localAudioTracks: local?.getAudioTracks().length ?? 0,
        localVideoTracks: local?.getVideoTracks().length ?? 0,
        signalingState: (await pc.getSignalingState()).toString(),
        iceGatheringState: (await pc.getIceGatheringState()).toString(),
        iceConnectionState: (await pc.getIceConnectionState()).toString(),
        connectionState: (await pc.getConnectionState()).toString(),
        remoteAudio: remoteAudio,
        remoteVideo: remoteVideo,
        stats: stats,
      );
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
        final marker = parseSfuMarker((ev['sdp'] ?? '').toString());
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
      case 'call_renegotiate':
        _onRenegotiate(ev);
      case 'call_ended':
        _onEnded(ev);
    }
  }

  /// SFU group invite (marker sdp): route to the group stack, never P2P.
  void _routeGroupInvite(
    Map<String, dynamic> ev,
    ({String room, bool video}) marker,
  ) {
    const prefix = 'grchat_';
    if (!marker.room.startsWith(prefix)) return;
    final dmId = marker.room.substring(prefix.length);
    if (dmId.isEmpty) return;
    final callId = ev['call_id']?.toString();
    if (callId == null) return;
    ref
        .read(groupCallProvider.notifier)
        .incoming(
          callId: callId,
          dmId: dmId,
          room: marker.room,
          video: marker.video,
          fromNick: (ev['from_nick'] ?? '?').toString(),
        );
  }

  /// Peer renegotiation. Two shapes, separated by the `answer` flag:
  /// • offer (peer enabled their camera): apply, answer back;
  /// • answer (to OUR earlier offer): completes [enableCamera]'s wait.
  void _onRenegotiate(Map<String, dynamic> ev) {
    final cur = state;
    if (cur == null || ev['call_id'] != cur.callId || _pc == null) return;
    if ((ev['answer'] ?? false) == true) {
      unawaited(_applyRenegeAnswer(ev));
    } else {
      unawaited(_applyRenegeOffer(ev));
    }
  }

  Future<void> _applyRenegeAnswer(Map<String, dynamic> ev) async {
    final wait = _renegoWait;
    try {
      final sdp = (ev['sdp'] ?? '').toString();
      if (sdp.isEmpty) throw StateError('empty renegotiate answer');
      dlog('renegotiate answer ${SdpSummary.parse(sdp)}');
      await _pc?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _remoteDescSet = true;
      await _flushRemoteIce();
      if (wait != null && !wait.isCompleted) wait.complete(true);
    } catch (e) {
      dlog('renegotiate answer failed: $e');
      if (wait != null && !wait.isCompleted) wait.complete(false);
    }
  }

  /// Peer enabled the camera mid-call: same shape as the initial answer
  /// handshake, but with roles swapped — we set their offer, answer, and
  /// send the answer back through the same verb.
  Future<void> _applyRenegeOffer(Map<String, dynamic> ev) async {
    final cur = state;
    final pc = _pc;
    if (cur == null || pc == null || cur.phase != CallPhase.active) return;
    try {
      final sdp = (ev['sdp'] ?? '').toString();
      if (sdp.isEmpty) return;
      dlog('peer renegotiate offer ${SdpSummary.parse(sdp)}');
      // Semantic note: `video` means OUR camera is on. Receiving the peer's
      // late camera does NOT flip theirs — the receiver widens via
      // remoteVideo (onTrack) and keeps the PiP slot hidden until they
      // turn their own camera on with the now-working button.
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteDescSet = true;
      await _flushRemoteIce();
      final rawAnswer = await pc.createAnswer({});
      final answer = RTCSessionDescription(
        tuneOpusSdp(rawAnswer.sdp ?? ''),
        rawAnswer.type,
      );
      await pc.setLocalDescription(answer);
      final out = (await pc.getLocalDescription())?.sdp ?? '';
      dlog('renegotiate answer ${SdpSummary.parse(out)}');
      await ref
          .read(callApiProvider)
          .renegotiate(callId: cur.callId, sdp: out, answer: true);
      dlog('peer renegotiation answered');
    } catch (e) {
      dlog('peer renegotiate failed: $e');
    }
  }

  /// Caller side: the answer SDP must become the remote description,
  /// otherwise signaling completes but no media flows.
  Future<void> _onAccepted(Map<String, dynamic> ev) async {
    final cur = state;
    if (cur == null || !cur.outgoing || ev['call_id'] != cur.callId) {
      return;
    }
    try {
      final sdp = (ev['sdp'] ?? '').toString();
      if (sdp.isNotEmpty) {
        dlog('answer ${SdpSummary.parse(sdp)}');
        await _pc?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
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
        ref
            .read(callRedialProvider.notifier)
            .offer(
              CallRedial(
                reason: reason == 'declined'
                    ? '$by отклонил звонок'
                    : 'Нет ответа',
                peerNick: cur.dmId == null ? cur.peerNick : null,
                dmId: cur.dmId,
                video: cur.video,
              ),
            );
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
          video: disp.video,
        );
      }
      return;
    }
    await _cleanup();
  }

  /// Test seam: drive a dry-ring incoming without WebRTC (headless-safe:
  /// no PC or media is created at ring time by design).
  @visibleForTesting
  Future<void> debugIncomingForTest({
    required String callId,
    required String peerNick,
    required bool video,
    String sdp = '',
  }) =>
      _prepareIncoming({'call_id': callId, 'from_nick': peerNick, 'sdp': sdp});

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
        remoteVideoArrived: false,
      );
      // Safety net if the caller never hangs up (old client / no sweep).
      _ringTimer?.cancel();
      _ringTimer = Timer(const Duration(seconds: 58), () async {
        final c = state;
        if (c == null || c.callId != callId || c.phase != CallPhase.ringing) {
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
    RTCPeerConnection pc,
    Map<String, String?> p,
  ) async {
    try {
      await pc.addCandidate(
        RTCIceCandidate(
          p['candidate'] ?? '',
          p['sdpMid'],
          p['sdpMLineIndex'] == null
              ? 0
              : int.tryParse(p['sdpMLineIndex'].toString()) ?? 0,
        ),
      );
      dlog(
        'ice remote added ${iceDigest(p['candidate'])} '
        'mid=${p['sdpMid']}',
      );
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
    _videoTransceiver = null;
    _captureMissingAtStart = false;
    // A pending late-camera wait must not outlive the call.
    _renegoWait?.complete(false);
    _renegoWait = null;
    _renegoLock = false;
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
    await _releaseStream(_local, 'call end');
    _local = null;
    await _releaseStream(_localVideo, 'call end');
    _localVideo = null;
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

final callStateProvider = NotifierProvider<CallState, ActiveCall?>(
  CallState.new,
);

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

final callNoticeProvider = NotifierProvider<CallNotice, String?>(
  CallNotice.new,
);

/// Redial offer after an unanswered outgoing call (§94): the ringing call
/// ended (local timeout or peer decline) and the user gets the reason plus a
/// "Позвонить снова" action instead of a dead-end toast.
class CallRedial {
  const CallRedial({
    required this.reason,
    required this.peerNick,
    required this.dmId,
    required this.video,
  });
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

final callRedialProvider = NotifierProvider<CallRedialStack, CallRedial?>(
  CallRedialStack.new,
);
