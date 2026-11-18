// Stage 2C - shared native media harness.
//
// Built directly on the facts proven by the Stage 2C feasibility PoC:
//   * every callback is wired BEFORE any SDP operation, otherwise candidates
//     emitted during gathering are lost forever;
//   * candidates are buffered until the target peer has a remote description,
//     because addCandidate throws otherwise and the throw must be RECORDED,
//     not swallowed inside a fire-and-forget future;
//   * native polling (getIceConnectionState / getConnectionState /
//     getIceGatheringState) is the source of truth; the event-fed fields proved
//     unreliable in the test host.
//
// This harness is test-only code. It is not imported by the production client.

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Serialised async work queue. Every candidate application is chained onto one
/// tail future, so ordering is deterministic and each failure is captured in
/// [errors] instead of disappearing into an unhandled async error.
class SerialQueue {
  Future<void> _tail = Future<void>.value();
  final List<String> errors = [];

  void add(String label, Future<void> Function() action) {
    _tail = _tail.then((_) async {
      try {
        await action();
      } catch (e) {
        errors.add('$label failed: $e');
      }
    });
  }

  Future<void> get idle => _tail;
}

/// Real capture source selection facts.
class MediaSource {
  MediaSource(this.kind, this.deviceId, this.label);
  final String kind;
  final String deviceId;
  final String label;

  @override
  String toString() => '$kind "${_mask(label)}" (${_short(deviceId)})';
}

String _short(String id) => id.length <= 8 ? id : '${id.substring(0, 8)}…';

String _mask(String label) {
  // Device labels are user hardware names; keep them short and non-identifying
  // enough for a report while still distinguishing devices from each other.
  return label.length <= 28 ? label : '${label.substring(0, 28)}…';
}

/// Enumerates real capture devices.
Future<List<MediaSource>> enumerateCapture(String kind) async {
  final all = await navigator.mediaDevices.enumerateDevices();
  return all
      .where((d) => d.kind == kind)
      .map((d) => MediaSource(kind, d.deviceId, d.label))
      .toList(growable: false);
}

/// Opens a real capture stream, pinned to a specific device when [deviceId] is
/// given. Returns null instead of throwing so callers can walk alternatives.
Future<MediaStream?> openCapture({
  required bool audio,
  required bool video,
  String? audioDeviceId,
  String? videoDeviceId,
}) async {
  try {
    final constraints = <String, dynamic>{
      if (audio)
        'audio': audioDeviceId == null
            ? true
            : <String, dynamic>{
                'deviceId': audioDeviceId,
                'optional': [
                  {'deviceId': audioDeviceId},
                ],
              },
      if (video)
        'video': videoDeviceId == null
            ? true
            : <String, dynamic>{
                'deviceId': videoDeviceId,
                'optional': [
                  {'deviceId': videoDeviceId},
                ],
              },
    };
    return await navigator.mediaDevices.getUserMedia(constraints);
  } catch (_) {
    return null;
  }
}

/// One side of the pair under test.
class MediaPeer {
  final String name;
  final RTCPeerConnection pc;
  final List<MediaStreamTrack> remoteTracks = [];
  final List<String> stateLog = [];
  final List<RTCIceCandidate> outboundQueue = [];
  final SerialQueue queue = SerialQueue();

  MediaPeer? remote;
  bool remoteDescriptionSet = false;

  int candidatesReceived = 0;
  int candidatesApplied = 0;
  int candidatesFailed = 0;

  MediaPeer._(this.pc, this.name);

  static Future<MediaPeer> create(
    String name, {
    Map<String, dynamic>? iceConfig,
  }) async {
    // iceServers is empty on purpose: this harness runs both peers on the same
    // host, so host candidates are sufficient and no STUN/TURN dependency is
    // introduced into the verification path.
    final pc = await createPeerConnection(
      iceConfig ?? {'iceServers': <dynamic>[]},
    );
    return MediaPeer._(pc, name);
  }

  /// Must be called before any SDP operation.
  void wire() {
    pc.onIceCandidate = (c) {
      candidatesReceived++;
      outboundQueue.add(c);
      unawaited(drainToRemote());
    };
    pc.onSignalingState = (s) => stateLog.add('signaling=$s');
    pc.onIceConnectionState = (s) => stateLog.add('ice=$s');
    pc.onConnectionState = (s) => stateLog.add('conn=$s');
    pc.onIceGatheringState = (s) => stateLog.add('gather=$s');
    pc.onTrack = (event) {
      remoteTracks.add(event.track);
      stateLog.add('onTrack kind=${event.track.kind} id=${event.track.id}');
    };
    pc.onAddStream = (stream) {
      stateLog.add('onAddStream tracks=${stream.getTracks().length}');
    };
  }

  /// Delivers buffered candidates to the remote peer, but only once that peer
  /// has a remote description. Public because the test drives negotiation
  /// step-by-step and must flush at explicit points.
  Future<void> drainToRemote() async {
    final target = remote;
    if (target == null || !target.remoteDescriptionSet) return;
    while (outboundQueue.isNotEmpty) {
      final c = outboundQueue.removeAt(0);
      // addCandidate can fail for a stale or mismatched candidate; record it.
      queue.add('$name->${target.name}', () async {
        try {
          await target.pc.addCandidate(c);
          candidatesApplied++;
        } catch (_) {
          candidatesFailed++;
          rethrow;
        }
      });
    }
    await queue.idle;
  }

  /// Adds every track of a real capture stream to this peer.
  Future<List<MediaStreamTrack>> attach(MediaStream stream) async {
    final added = <MediaStreamTrack>[];
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
      added.add(track);
    }
    return added;
  }

  /// Candidate summary that hides addresses/ports but keeps the candidate type,
  /// which is the only part relevant to a connectivity diagnosis.
  static String describeCandidate(RTCIceCandidate c) {
    final raw = c.candidate ?? '';
    final type = RegExp(r'typ (\w+)').firstMatch(raw)?.group(1) ?? '?';
    return type;
  }

  Future<void> close() async {
    pc.onIceCandidate = null;
    pc.onIceGatheringState = null;
    pc.onIceConnectionState = null;
    pc.onConnectionState = null;
    pc.onSignalingState = null;
    pc.onTrack = null;
    pc.onAddStream = null;
    await pc.close();
  }
}

/// Runs one full offer/answer negotiation between two peers.
Future<void> negotiate(MediaPeer offerer, MediaPeer answerer) async {
  offerer.remote = answerer;
  answerer.remote = offerer;

  final offer = await offerer.pc.createOffer({
    'offerToReceiveAudio': 1,
    'offerToReceiveVideo': 1,
  });
  await offerer.pc.setLocalDescription(offer);
  await answerer.pc.setRemoteDescription(offer);
  answerer.remoteDescriptionSet = true;
  await offerer.drainToRemote();

  final answer = await answerer.pc.createAnswer();
  await answerer.pc.setLocalDescription(answer);
  await offerer.pc.setRemoteDescription(answer);
  offerer.remoteDescriptionSet = true;
  await answerer.drainToRemote();

  await offerer.queue.idle;
  await answerer.queue.idle;
}

/// Polls the NATIVE connection state until both peers are up. Returns false on
/// timeout with a caller-supplied diagnostic already produced.
Future<bool> waitForIceUp(
  MediaPeer a,
  MediaPeer b, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final sa = await a.pc.getIceConnectionState();
    final sb = await b.pc.getIceConnectionState();
    if (_isUp(sa) && _isUp(sb)) return true;
    await Future.delayed(const Duration(milliseconds: 250));
  }
  return false;
}

bool _isUp(RTCIceConnectionState? s) {
  final t = (s?.toString() ?? '').toLowerCase();
  return t.contains('connected') || t.contains('completed');
}

/// Collects stats of one report [type] from a peer.
Future<List<StatsReport>> statsOfType(MediaPeer peer, String type) async {
  final all = await peer.pc.getStats();
  return all.where((r) => r.type == type).toList(growable: false);
}

/// Reads a numeric stat value, tolerating any schema change by returning null.
num? statValue(StatsReport report, String key) {
  final v = report.values[key];
  return v is num ? v : null;
}

/// Picks the report matching [kind] (audio/video) if the runtime provides it.
StatsReport? byKind(List<StatsReport> reports, String kind) {
  for (final r in reports) {
    if (r.values['kind'] == kind) return r;
  }
  return null;
}

/// Extracts the ice-ufrag of a local SDP, used to prove a new ICE generation.
String iceUfrag(RTCSessionDescription? d) {
  final sdp = d?.sdp;
  if (sdp == null) return '<none>';
  return RegExp(r'a=ice-ufrag:(\S+)').firstMatch(sdp)?.group(1) ?? '<none>';
}

/// Polls a condition with a bounded budget. Returns null on timeout.
Future<T?> waitUntil<T>(
  Future<T?> Function() probe, {
  required Duration timeout,
  required Duration step,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final v = await probe();
    if (v != null) return v;
    await Future.delayed(step);
  }
  return null;
}
