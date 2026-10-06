import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:riverpod/riverpod.dart';

import '../app/providers.dart';
import '../auth/auth_repository.dart';
import 'call_api.dart';
import 'call_diagnostics.dart';
import 'group_call.dart' show groupCallProvider;
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
  StreamSubscription<Map<String, dynamic>>? _pushSub;
  final _pendingIce = <Map<String, String?>>[];
  String? _callId;

  // Remote side (§15, §20): candidates before setRemoteDescription wait
  // in [_remoteIce]; remote tracks land in [_remoteStream].
  final _remoteIce = IceBuffer<Map<String, String?>>();
  MediaStream? _remoteStream;
  bool _remoteDescSet = false;

  /// A remote video track has arrived at least once. Tracked separately from
  /// [ActiveCall.remoteVideo] because _prepareIncoming rebuilds the ringing
  /// state from scratch *after* setRemoteDescription, and onTrack has already
  /// fired by then - a fresh object would silently drop the flag and leave
  /// the callee staring at "Подключение видео…" forever.
  bool _remoteVideoArrived = false;

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

  Future<void> _addLocal(RTCPeerConnection pc, bool video) async {
    _local = await navigator.mediaDevices
        .getUserMedia({'audio': true, 'video': video});
    final tracks = _local!.getTracks();
    dlog('getUserMedia audio=${_local!.getAudioTracks().length} '
        'video=${_local!.getVideoTracks().length}');
    for (final t in tracks) {
      dlog('local track kind=${t.kind} id=${t.id} enabled=${t.enabled}');
      final sender = await pc.addTrack(t, _local!);
      if (t.kind == 'video') _videoSender = sender;
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
    try {
      _pc = await _newPc('');
      await _addLocal(_pc!, video);
      final offer = await _pc!.createOffer({});
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
          await hangup();
        });
      }
    } catch (e) {
      await _cleanup();
      rethrow;
    }
  }

  Future<void> acceptIncoming() async {
    final cur = state;
    if (cur == null || cur.outgoing) return;
    ref.read(callRedialProvider.notifier).clear();
    final api = ref.read(callApiProvider);
    try {
      final answer = await _pc!.createAnswer({});
      await _pc!.setLocalDescription(answer);
      final sdp = (await _pc!.getLocalDescription())?.sdp ?? '';
      dlog('answer ${SdpSummary.parse(sdp)}');
      await api.answer(callId: cur.callId, accept: true, sdp: sdp);
      _ringTimer?.cancel();
      // Patch the live state instead of writing back the pre-await snapshot:
      // onTrack may have delivered a remote video track meanwhile.
      state = state?.copyWith(phase: CallPhase.active);
    } catch (e) {
      await decline();
      rethrow;
    }
  }

  Future<void> decline() async {
    final cur = state;
    if (cur == null) return;
    try {
      await ref.read(callApiProvider).answer(callId: cur.callId, accept: false);
    } catch (_) {}
    await _cleanup();
  }

  Future<void> hangup() async {
    final cur = state;
    if (cur == null) return;
    try {
      await ref.read(callApiProvider).hangup(cur.callId);
    } catch (_) {}
    await _cleanup();
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
        if (state != null) {
          // Busy: decline so the caller hears it instead of ringing 60s.
          final id = ev['call_id']?.toString();
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
        if (ref.read(groupCallProvider) != null) {
          // Busy on a group call: same courtesy decline.
          final id = ev['call_id']?.toString();
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
    } catch (_) {
      await hangup();
    }
  }

  void _onEnded(Map<String, dynamic> ev) {
    final cur = state;
    if (cur == null || ev['call_id'] != cur.callId) return;
    final reason = ev['reason']?.toString() ?? '';
    final by = (ev['by_nick'] ?? cur.peerNick).toString();
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
    _cleanup();
  }

  Future<void> _prepareIncoming(Map<String, dynamic> ev) async {
    try {
      ref.read(callRedialProvider.notifier).clear();
      final callId = ev['call_id'] as String;
      final sdp = (ev['sdp'] ?? '') as String;
      final video = sdp.contains('m=video');
      _callId = callId;
      _pc = await _newPc(callId);
      await _addLocal(_pc!, video);
      dlog('offer ${SdpSummary.parse(sdp)}');
      await _pc!.setRemoteDescription(
          RTCSessionDescription(sdp, 'offer'));
      _remoteDescSet = true;
      await _flushRemoteIce();
      state = incomingRingingCall(
          callId: callId,
          peerNick: (ev['from_nick'] ?? '?') as String,
          video: video,
          // onTrack already ran during setRemoteDescription above.
          remoteVideoArrived: _remoteVideoArrived);
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
      await _cleanup();
    }
  }

  Future<void> _onRemoteIce(Map<String, dynamic> ev) async {
    final pc = _pc;
    if (pc == null || state == null || ev['call_id'] != state!.callId) {
      return;
    }
    final payload = {
      'candidate': (ev['candidate'] ?? '').toString(),
      'sdpMid': ev['sdp_mid']?.toString(),
      'sdpMLineIndex': ev['sdp_mline_index']?.toString(),
    };
    if (!_remoteDescSet) {
      // Race (§15): queue, never drop.
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
    _pendingIce.clear();
    _remoteIce.clear();
    _remoteDescSet = false;
    _remoteVideoArrived = false;
    _ringTimer?.cancel();
    _ringTimer = null;
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
    state = null;
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
