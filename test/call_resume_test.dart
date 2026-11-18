import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/call/call_api.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';
import 'package:grchat_client/src/transport/server_sign.dart';

/// Talks to a fake server that speaks the real Stage 2A `call_resume`
/// contract, so the client's request shape and its reading of the snapshot are
/// both checked against the server implementation rather than a guess.
class _ResumeServer {
  late final ServerSocket socket;
  final seen = <Map<String, dynamic>>[];
  String? refuseCode;

  int get port => socket.port;

  Future<void> start() async {
    socket = await ServerSocket.bind('127.0.0.1', 0);
    socket.listen((s) {
      s.cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        try {
          final m = jsonDecode(line) as Map<String, dynamic>;
          seen.add(m);
          if (m['type'] != 'call_resume') return;
          final id = m['req_id']?.toString();
          final code = refuseCode;
          if (code != null) {
            s.write('${jsonEncode({
                  'v': 1,
                  'type': 'error',
                  'req_id': id,
                  'code': code,
                })}\n');
            return;
          }
          s.write('${jsonEncode({
                'v': 1,
                'type': 'call_resumed',
                'req_id': id,
                'call_id': 'call-42',
                'phase': 'active',
                'video': true,
                'members': 2,
                'server_time_ms': 1767225602000,
                'recovery_epoch': 1,
                'accepted_at_ms': 1767225600000,
                'recovering': false,
              })}\n');
        } catch (_) {}
      }, onError: (_) {});
    });
  }

  Future<void> stop() => socket.close();
}

void main() {
  late _ResumeServer s;

  setUp(() async {
    s = _ResumeServer();
    await s.start();
  });

  tearDown(() async {
    await s.stop();
  });

  Future<(GrchatConnection, CallApi)> wire() async {
    final conn = GrchatConnection(
      connector: (h, p) => Socket.connect(h, p, timeout: const Duration(seconds: 5)),
      verifier: (_) async => ServerSigCheck.ok,
    );
    await conn.connect('127.0.0.1', s.port);
    // The token is opaque to the transport: it only has to be forwarded.
    final api = CallApi(conn, Session(userId: 'u1', nick: 'n', token: 'tok'));
    return (conn, api);
  }

  group('call_resume wire contract', () {
    test('sends only the identifiers the server expects', () async {
      final (conn, api) = await wire();
      final snap = await api.resume('call-42');
      expect(snap, isNotNull);
      final sent = s.seen.firstWhere((m) => m['type'] == 'call_resume');
      // Stage 2A reads exactly these three fields: type, session_token, call_id.
      expect(sent['session_token'], 'tok');
      expect(sent['call_id'], 'call-42');
      expect(sent['v'], 1);
      expect(sent.containsKey('sdp'), isFalse,
          reason: 'a resume carries no media and must not re-negotiate');
      await conn.dispose();
    });

    test('reads the authoritative snapshot', () async {
      final (conn, api) = await wire();
      final snap = await api.resume('call-42');
      expect(snap!.callId, 'call-42');
      expect(snap.phase, 'active');
      expect(snap.isActive, isTrue);
      expect(snap.video, isTrue);
      expect(snap.members, 2);
      expect(snap.recoveryEpoch, 1);
      expect(snap.acceptedAtMs, 1767225600000,
          reason: 'the conversation start must survive recovery');
      expect(snap.recovering, isFalse);
      await conn.dispose();
    });

    test('a refusal yields null and is not an exception to retry', () async {
      s.refuseCode = 'NOT_CALL_OWNER';
      final (conn, api) = await wire();
      expect(await api.resume('call-42'), isNull,
          reason: 'an unauthorized session must stay refused');
      await conn.dispose();
    });
  });

  group('resume reconciliation (Stage 2E)', () {
    const r = ResumeReconciler();

    CallSnapshot snap({
      String callId = 'call-42',
      int epoch = 1,
      String phase = 'active',
    }) =>
        CallSnapshot(
          callId: callId,
          phase: phase,
          video: true,
          members: 2,
          serverTimeMs: 0,
          recoveryEpoch: epoch,
          acceptedAtMs: 1,
          recovering: false,
        );

    test('no local call means nothing to reconcile', () {
      expect(
        r.decide(
            localCallId: null,
            localEnded: false,
            localRecoveryEpoch: 0,
            snapshot: snap()),
        ResumeOutcome.noCall,
      );
    });

    test('an explicit hangup is final - a late resume never revives it', () {
      expect(
        r.decide(
            localCallId: 'call-42',
            localEnded: true,
            localRecoveryEpoch: 0,
            snapshot: snap()),
        ResumeOutcome.refuse,
        reason: 'hangup stays final even if the server still lists the call',
      );
    });

    test('a snapshot for another call is refused', () {
      expect(
        r.decide(
            localCallId: 'call-42',
            localEnded: false,
            localRecoveryEpoch: 0,
            snapshot: snap(callId: 'call-99')),
        ResumeOutcome.refuse,
      );
    });

    test('an older recovery epoch is stale and does not overwrite', () {
      expect(
        r.decide(
            localCallId: 'call-42',
            localEnded: false,
            localRecoveryEpoch: 3,
            snapshot: snap(epoch: 1)),
        ResumeOutcome.refuse,
      );
      expect(
        r.decide(
            localCallId: 'call-42',
            localEnded: false,
            localRecoveryEpoch: 1,
            snapshot: snap(epoch: 2)),
        ResumeOutcome.keep,
      );
    });

    test('a missing snapshot is never a reason to end the call', () {
      // The comparator itself never ends anything: absence of an answer is
      // handled by the recovery driver (reported as `refused`), so this stays
      // `keep` - a call whose media still flows must not be torn down here.
      expect(
        r.decide(
            localCallId: 'call-42',
            localEnded: false,
            localRecoveryEpoch: 0,
            snapshot: null),
        ResumeOutcome.keep,
      );
    });
  });
}
