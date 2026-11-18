import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'rtp_harness.dart';
import 'rtp_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('R2 selected ICE route carries audio and video RTP', () async {
    final env = Platform.environment;
    final mode = env['GRCHAT_R2_ICE_MODE'] ?? 'direct';
    expect(['direct', 'stun', 'turn-udp', 'turn-tcp'], contains(mode));
    final port = int.tryParse(env['GRCHAT_R2_TURN_PORT'] ?? '3478');
    expect(port, inInclusiveRange(1, 65535));
    final relay = mode.startsWith('turn-');
    final user = env['GRCHAT_R2_TURN_USER'];
    final password = env['GRCHAT_R2_TURN_PASSWORD'];
    if (relay) {
      expect(user, isNotNull, reason: 'provide disposable TURN credentials');
      expect(
        password,
        isNotNull,
        reason: 'provide disposable TURN credentials',
      );
    }
    final config = <String, dynamic>{
      'iceTransportPolicy': relay ? 'relay' : 'all',
      'iceServers': [
        if (mode == 'stun') {'urls': 'stun:127.0.0.1:$port'},
        if (relay)
          {
            'urls': 'turn:127.0.0.1:$port?transport=${mode.substring(5)}',
            'username': user,
            'credential': password,
          },
      ],
    };
    final clock = Stopwatch()..start();
    final pair = await connectWorkingPair(iceConfig: config);
    final setupMs = clock.elapsedMilliseconds;
    addTearDown(pair.teardown);
    final reports = await pair.b.pc.getStats();
    final routeIds = reports
        .where((report) => report.type == 'transport')
        .map((report) => report.values['selectedCandidatePairId'])
        .whereType<String>()
        .toSet();
    final route = reports.singleWhere(
      (report) =>
          report.type == 'candidate-pair' && routeIds.contains(report.id),
    );
    String? candidateType(String key) =>
        reports
                .singleWhere((report) => report.id == route.values[key])
                .values['candidateType']
            as String?;
    final local = candidateType('localCandidateId');
    final remote = candidateType('remoteCandidateId');
    if (relay) {
      expect([local, remote], everyElement('relay'));
    } else if (mode == 'stun') {
      expect([local, remote], contains('srflx'));
    } else {
      expect([local, remote], everyElement('host'));
    }
    final before = await inboundSnapshot(pair.b);
    final sampleTime = Stopwatch()..start();
    await Future<void>.delayed(const Duration(seconds: 3));
    final after = await inboundSnapshot(pair.b);
    expect(after.audio, greaterThan(before.audio));
    expect(after.video, greaterThan(before.video));
    final inbound = await statsOfType(pair.b, 'inbound-rtp');
    // Numeric telemetry only. Addresses, SDP and credentials stay in memory.
    // ignore: avoid_print
    print(
      'R2_ROUTE ${jsonEncode({
        'mode': mode,
        'local': local,
        'remote': remote,
        'setup_to_rtp_ms': setupMs,
        'sample_ms': sampleTime.elapsedMilliseconds,
        'audio_packets': after.audio - before.audio,
        'video_packets': after.video - before.video,
        'rtt_seconds': route.values['currentRoundTripTime'],
        'inbound': [
          for (final stat in inbound) {'kind': stat.values['kind'], 'bytes_received': statValue(stat, 'bytesReceived'), 'packets_lost': statValue(stat, 'packetsLost'), 'jitter_seconds': statValue(stat, 'jitter')},
        ],
      })}',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
