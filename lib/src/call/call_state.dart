import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:riverpod/riverpod.dart';

import '../app/providers.dart';
import 'call_api.dart';

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
  });

  final String callId;
  final String peerNick;
  final bool video;
  final bool outgoing;
  final CallPhase phase;
  final bool muted;
  final bool cameraOff;

  ActiveCall copyWith({
    CallPhase? phase,
    bool? muted,
    bool? cameraOff,
  }) =>
      ActiveCall(
        callId: callId,
        peerNick: peerNick,
        video: video,
        outgoing: outgoing,
        phase: phase ?? this.phase,
        muted: muted ?? this.muted,
        cameraOff: cameraOff ?? this.cameraOff,
      );
}

final callApiProvider = Provider<CallApi>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) throw StateError('no session');
  return CallApi(ref.watch(connectionProvider), s);
});

class CallState extends Notifier<ActiveCall?> {
  RTCPeerConnection? _pc;
  MediaStream? _local;
  RTCVideoRenderer? _localR;
  RTCVideoRenderer? _remoteR;
  StreamSubscription<Map<String, dynamic>>? _pushSub;
  final _pendingIce = <Map<String, String?>>[];
  String? _callId;

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
    pc.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
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
    pc.onAddStream = (s) {
      _remoteR?.srcObject = s;
      state = state?.copyWith();
    };
    return pc;
  }

  Future<void> _addLocal(RTCPeerConnection pc, bool video) async {
    _local = await navigator.mediaDevices
        .getUserMedia({'audio': true, 'video': video});
    for (final t in _local!.getTracks()) {
      await pc.addTrack(t, _local!);
    }
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
            phase: CallPhase.ringing);
      }
    } catch (e) {
      await _cleanup();
      rethrow;
    }
  }

  Future<void> acceptIncoming() async {
    final cur = state;
    if (cur == null || cur.outgoing) return;
    final api = ref.read(callApiProvider);
    try {
      final answer = await _pc!.createAnswer({});
      await _pc!.setLocalDescription(answer);
      final sdp = (await _pc!.getLocalDescription())?.sdp ?? '';
      await api.answer(callId: cur.callId, accept: true, sdp: sdp);
      state = cur.copyWith(phase: CallPhase.active);
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

  void _onPush(Map<String, dynamic> ev) {
    switch (ev['type']?.toString()) {
      case 'call_incoming':
        if (state != null) return; // busy: ignore
        _prepareIncoming(ev);
      case 'call_accepted':
        if (state != null && ev['call_id'] == state!.callId) {
          state = state!.copyWith(phase: CallPhase.active);
        }
      case 'ice':
        _onRemoteIce(ev);
      case 'call_ended':
        if (state != null && ev['call_id'] == state!.callId) {
          _cleanup();
        }
    }
  }

  Future<void> _prepareIncoming(Map<String, dynamic> ev) async {
    try {
      final callId = ev['call_id'] as String;
      final sdp = (ev['sdp'] ?? '') as String;
      final video = sdp.contains('m=video');
      _callId = callId;
      _pc = await _newPc(callId);
      await _addLocal(_pc!, video);
      await _pc!.setRemoteDescription(
          RTCSessionDescription(sdp, 'offer'));
      state = ActiveCall(
          callId: callId,
          peerNick: (ev['from_nick'] ?? '?') as String,
          video: video,
          outgoing: false,
          phase: CallPhase.ringing);
    } catch (_) {
      await _cleanup();
    }
  }

  Future<void> _onRemoteIce(Map<String, dynamic> ev) async {
    final pc = _pc;
    if (pc == null || state == null || ev['call_id'] != state!.callId) {
      return;
    }
    try {
      await pc.addCandidate(RTCIceCandidate(
        (ev['candidate'] ?? '') as String,
        ev['sdp_mid']?.toString(),
        ev['sdp_mline_index'] == null
            ? 0
            : int.tryParse(ev['sdp_mline_index'].toString()) ?? 0,
      ));
    } catch (_) {}
  }

  Future<void> _cleanup() async {
    _callId = null;
    _pendingIce.clear();
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      await _local?.dispose();
    } catch (_) {}
    _local = null;
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
