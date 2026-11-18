// Stage 2C.R1 - MEDIA SOURCE PROBE.
//
// Answers the one question that decides the whole RTP harness design:
// does the Windows test runner expose REAL capture devices, and can
// getUserMedia produce genuine audio/video tracks there?
//
// This probe asserts nothing about availability on purpose: its job is to
// report facts. Availability is decided from the output, not forced by an
// assertion that would hide the real state.
//
// No virtual capture device is installed or simulated. If the machine has no
// usable camera/microphone, this probe says so and the harness design changes
// accordingly - it never fabricates tracks.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

/// Device ids are un-guessable but still environment-identifying; show only a
/// short prefix so the report can prove "real distinct device" without leaking.
String _shortId(String id) =>
    id.isEmpty ? '<empty>' : '${id.substring(0, id.length < 8 ? id.length : 8)}…';

void _dumpDevices(String kind) {
  // ignore: avoid_print
  print('DEVICES[$kind] pending');
}

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('probe real capture devices in the Windows test runner', () async {
    // ---- 1. enumeration ----
    for (final kind in ['audioinput', 'videoinput', 'audiooutput']) {
      try {
        final devs = await navigator.mediaDevices.enumerateDevices();
        final filtered =
            devs.where((d) => d.kind == kind).toList(growable: false);
        // ignore: avoid_print
        print('DEVICES[$kind] count=${filtered.length} '
            'all=${devs.map((d) => d.kind).toSet().toList()}');
        for (final d in filtered) {
          // ignore: avoid_print
          print('DEVICES[$kind] id=${_shortId(d.deviceId)} '
              'label="${d.label}" group=${d.groupId == null ? 'null' : 'set'}');
        }
      } catch (e) {
        _dumpDevices(kind);
        // ignore: avoid_print
        print('DEVICES[$kind] ERROR $e');
      }
    }

    // ---- 2. real getUserMedia attempts ----
    final results = <String>[];
    final opened = <MediaStream>[];

    Future<void> probe(String label, Map<String, dynamic> constraints) async {
      final sw = Stopwatch()..start();
      try {
        final stream = await navigator.mediaDevices.getUserMedia(constraints);
        sw.stop();
        opened.add(stream);
        final tracks = stream.getTracks();
        results.add('$label OK ${sw.elapsedMilliseconds}ms tracks=${tracks.length}');
        // ignore: avoid_print
        print('GUM[$label] OK in ${sw.elapsedMilliseconds}ms tracks=${tracks.length}');
        for (final t in tracks) {
          // ignore: avoid_print
          print('GUM[$label] track kind=${t.kind} id=${_shortId(t.id ?? '')} '
              'label="${t.label ?? '<null>'}" enabled=${t.enabled}');
        }
      } catch (e) {
        sw.stop();
        results.add('$label FAILED ${sw.elapsedMilliseconds}ms: $e');
        // ignore: avoid_print
        print('GUM[$label] FAILED in ${sw.elapsedMilliseconds}ms: $e');
      }
    }

    await probe('audio-only', {'audio': true});
    await probe('video-only', {'video': true});
    // The shape a real call actually negotiates: both kinds in one stream.
    await probe('audio+video', {'audio': true, 'video': true});

    // ---- 3. release every device again: a probe must not hold the hardware ----
    for (final s in opened) {
      try {
        await s.dispose();
      } catch (e) {
        // ignore: avoid_print
        print('DISPOSE ERROR $e');
      }
    }
    // ignore: avoid_print
    print('SUMMARY ${results.join(' || ')}');
    // ignore: avoid_print
    print('PROBE DONE');
  }, timeout: const Timeout(Duration(minutes: 5)));
}