// STAGE 2C / R4.2 - ICE GATHERING ROOT-CAUSE ISOLATION.
//
// Three configurations, in order, so one run separates three different causes:
//
//   CFG-1  iceServers: []            policy: all    -> baseline host gathering
//   CFG-2  iceServers: [public STUN] policy: all    -> does iceServers reach native?
//   CFG-3  iceServers: [local TURN]  policy: relay  -> is TURN the problem?
//
// Reading the results:
//   CFG-1 empty + CFG-2 empty  -> the harness or the plugin never gathers
//   CFG-1 host + CFG-2 empty  -> iceServers are NOT applied by the native layer
//   CFG-1 host + CFG-2 srflx  -> config plumbing works; TURN is the problem
//
// Only candidate OUTPUT is measured here - no SDP bodies, no credentials.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

const String turnUrl = 'turn:127.0.0.1:34780?transport=udp';

Future<Map<String, int>> probe(String label, Map<String, dynamic> cfg) async {
  final pc = await createPeerConnection(cfg);
  final types = <String, int>{};
  var gatherEnd = false;

  // Handlers are wired BEFORE any SDP work.
  pc.onIceGatheringState = (s) {
    if (s.toString().toLowerCase().contains('complete')) gatherEnd = true;
  };
  pc.onIceCandidate = (c) {
    final raw = c.candidate ?? '';
    if (raw.isEmpty) return;
    final m = RegExp(r'typ (\w+)').firstMatch(raw);
    final t = m?.group(1) ?? '?';
    types[t] = (types[t] ?? 0) + 1;
  };

  final offer = await pc.createOffer(
      <String, dynamic>{'offerToReceiveAudio': 1, 'offerToReceiveVideo': 1});
  await pc.setLocalDescription(offer);

  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline) && !gatherEnd) {
    await Future.delayed(const Duration(milliseconds: 200));
  }
  await Future.delayed(const Duration(seconds: 1));

  // What actually ended up in the local description.
  var sdpCandidates = 0;
  try {
    final d = await pc.getLocalDescription();
    sdpCandidates = (d?.sdp ?? '')
        .split('\r\n')
        .where((l) => l.startsWith('a=candidate'))
        .length;
  } catch (_) {
    sdpCandidates = -1;
  }

  // ignore: avoid_print
  print('PROBE $label gatheredTypes=$types gatheringComplete=$gatherEnd '
      'candidatesInLocalSdp=$sdpCandidates');
  await pc.close();
  return types;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('R4.2: isolate whether iceServers reach the native ICE agent', () async {
    // CFG-1: baseline. R5.4 proved host candidates appear on this host.
    final c1 = await probe('CFG-1-no-servers-all',
        <String, dynamic>{'iceServers': <dynamic>[], 'iceTransportPolicy': 'all'});
    // ignore: avoid_print
    print('RESULT CFG-1 host=${c1['host'] ?? 0}');

    // CFG-2: a public STUN server proves the plumbing end to end.
    final c2 = await probe('CFG-2-public-stun-all', <String, dynamic>{
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ],
      'iceTransportPolicy': 'all',
    });
    // ignore: avoid_print
    print('RESULT CFG-2 srflx=${c2['srflx'] ?? 0} host=${c2['host'] ?? 0}');

    // CFG-3: our local TURN, relay-only.
    final c3 = await probe('CFG-3-local-turn-relay', <String, dynamic>{
      'iceServers': [
        {
          'urls': turnUrl,
          'username': 'grchat',
          'credential': 'grchat-r4-testonly',
        }
      ],
      'iceTransportPolicy': 'relay',
    });
    // ignore: avoid_print
    print('RESULT CFG-3 relay=${c3['relay'] ?? 0} host=${c3['host'] ?? 0}');

    // ignore: avoid_print
    print('R4.2 PROBE DONE');
  }, timeout: const Timeout(Duration(minutes: 10)));
}