import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';
import 'package:grchat_client/src/transport/server_sign.dart';

/// Fake JSONL server. It keeps every accepted socket so a test can write raw
/// lines, kill a specific connection, and observe how many sockets the client's
/// reconnect loop actually opens.
class _FakeServer {
  late final ServerSocket socket;
  final sockets = <Socket>[];

  /// Indexes of sockets the peer has already destroyed.
  final dead = <int>{};

  int get port => socket.port;

  Future<void> start() async {
    socket = await ServerSocket.bind('127.0.0.1', 0);
    socket.listen((s) {
      final i = sockets.length;
      sockets.add(s);
      // A Socket is a SINGLE-subscription stream: attaching a second listener
      // would steal the bytes from the JSONL pipeline below. Liveness is
      // tracked through s.done (a Future, not a listener) so raw() can stop
      // writing to a peer the client already killed - Socket.write reports
      // failures on the stream, so a try/catch cannot catch them.
      final dead = <int>{};
      s.done.then((_) => dead.add(i), onError: (_) => dead.add(i));
      s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              try {
                final m = jsonDecode(line) as Map<String, dynamic>;
                if (m['type'] == 'ping') {
                  s.write(
                    '${jsonEncode({'v': 1, 'type': 'pong', 'req_id': m['req_id']})}\n',
                  );
                }
              } catch (_) {}
            },
            onError: (_) {
              // The client under test deliberately kills sockets in several cases;
              // that must not surface as an unhandled error inside the fake server.
            },
          );
    });
  }

  void raw(int i, String line) {
    // The client under test deliberately kills sockets in several cases (that
    // is exactly what several assertions verify), so never write to a peer it
    // has already dropped.
    if (dead.contains(i)) return;
    try {
      sockets[i].write('$line\n');
    } catch (_) {}
  }

  Future<void> stop() async {
    for (final s in sockets) {
      try {
        s.destroy();
      } catch (_) {}
    }
    await socket.close();
  }
}

String push(String tag) => jsonEncode({'v': 1, 'type': 'evt', 'tag': tag});

/// Collects pushes in arrival order.
List<String> collect(GrchatConnection c) {
  final out = <String>[];
  c.pushes.listen((m) => out.add(m['tag']?.toString() ?? '?'));
  return out;
}

void main() {
  late _FakeServer s;

  setUp(() async {
    s = _FakeServer();
    await s.start();
  });

  tearDown(() async {
    await s.stop();
  });

  GrchatConnection client({EnvelopeVerifier? verifier, int maxQueue = 512}) =>
      GrchatConnection(
        connector: (h, p) =>
            Socket.connect(h, p, timeout: const Duration(seconds: 5)),
        verifier: verifier,
        maxQueuedEnvelopes: maxQueue,
      );

  // ---------------- PART A: ordered dispatch ----------------

  // T01: verification of A is deliberately slow; B must not overtake it.
  test(
    'T01 envelopes are routed in arrival order even when A verifies slowly',
    () async {
      final c = client(
        verifier: (line) async {
          if (line.contains('"tag":"A"')) {
            await Future.delayed(const Duration(milliseconds: 120));
          }
          return ServerSigCheck.ok;
        },
      );
      await c.connect('127.0.0.1', s.port);
      final seen = collect(c);

      s.raw(0, push('A'));
      s.raw(0, push('B'));
      s.raw(0, push('C'));
      await Future.delayed(const Duration(milliseconds: 400));

      expect(seen, [
        'A',
        'B',
        'C',
      ], reason: 'slow signature verification must not reorder signalling');
      await c.dispose();
    },
  );

  // T02: a response and a push keep one shared order.
  test('T02 responses and pushes share one ordered chain', () async {
    final c = client();
    await c.connect('127.0.0.1', s.port);
    final seen = collect(c);

    // 'history' is not auto-answered by the fake server, so the only response
    // is the one written here below - the auto-pong would otherwise arrive as
    // an extra untagged "push".
    final future = c.request('history', reqId: 'r1');
    final settled = future.then((v) => v);
    s.raw(0, push('P1'));
    s.raw(0, jsonEncode({'v': 1, 'type': 'history', 'req_id': 'r1'}));
    s.raw(0, push('P2'));

    final resp = await settled;
    await Future.delayed(const Duration(milliseconds: 200));
    expect(resp['type'], 'history');
    expect(seen, ['P1', 'P2']);
    await c.dispose();
  });

  // T03: a bad signature is dropped whole - never reaches matcher or push stream.
  test('T03 a bad signature is never delivered', () async {
    final c = client(
      verifier: (line) async => line.contains('"tag":"EVIL"')
          ? ServerSigCheck.bad
          : ServerSigCheck.ok,
    );
    await c.connect('127.0.0.1', s.port);
    final seen = collect(c);

    s.raw(0, push('EVIL'));
    await Future.delayed(const Duration(milliseconds: 150));
    expect(seen, isEmpty, reason: 'Ed25519 failure must drop the envelope');

    // T04: and the chain keeps working afterwards.
    s.raw(0, push('GOOD'));
    await Future.delayed(const Duration(milliseconds: 200));
    expect(seen, ['GOOD'], reason: 'a rejected line must not stall the chain');
    await c.dispose();
  });

  // T05: the socket dies while a verification is in flight; the late result
  // must not be delivered into the next socket generation.
  test(
    'T05 a result verified after the socket died is not delivered',
    () async {
      final gate = Completer<void>();
      final c = client(
        verifier: (line) async {
          await gate.future;
          return ServerSigCheck.ok;
        },
      );
      await c.connect('127.0.0.1', s.port);
      final seen = collect(c);

      s.raw(0, push('LATE'));
      await Future.delayed(const Duration(milliseconds: 50));
      // Connection is replaced while the verification is still pending.
      s.sockets[0].destroy();
      await Future.delayed(const Duration(milliseconds: 100));
      gate.complete();
      await Future.delayed(const Duration(milliseconds: 200));

      expect(
        seen,
        isEmpty,
        reason: 'a retired generation must not deliver into the new one',
      );
      await c.dispose();
    },
  );

  // T06: a flood cannot grow the queue without bound. Signalling order cannot be
  // preserved by discarding an arbitrary line, so overflow drops the connection.
  test('T06 an inbound flood is bounded and fails safe', () async {
    final entered = <String>[];
    final gate = Completer<void>();
    final c = client(
      maxQueue: 4,
      verifier: (line) async {
        entered.add(line);
        await gate.future;
        return ServerSigCheck.ok;
      },
    );
    await c.connect('127.0.0.1', s.port);
    collect(c);

    for (var i = 0; i < 40; i++) {
      s.raw(0, push('n$i'));
    }
    await Future.delayed(const Duration(milliseconds: 300));

    expect(
      entered.length,
      lessThanOrEqualTo(4),
      reason: 'no more than the queue bound may be in flight',
    );
    expect(
      c.isOpen,
      isFalse,
      reason: 'overload must drop the connection, not silently drop events',
    );
    gate.complete();
    await c.dispose();
  });

  test(
    'new sockets retain their full queue capacity after repeated retirement',
    () async {
      final entered = <String, Completer<void>>{};
      final gates = <String, Completer<void>>{};
      final c = client(
        maxQueue: 3,
        verifier: (line) async {
          final tag =
              (jsonDecode(line) as Map<String, dynamic>)['tag'] as String;
          entered[tag]?.complete();
          await gates[tag]?.future;
          return ServerSigCheck.ok;
        },
      );
      addTearDown(c.dispose);
      final observed = collect(c);
      for (var i = 0; i < 4; i++) {
        final tag = 'blocked$i';
        entered[tag] = Completer<void>();
        gates[tag] = Completer<void>();
        await c.connect('127.0.0.1', s.port);
        while (s.sockets.length <= i) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        s.raw(i, push(tag));
        await entered[tag]!.future;
        s.raw(i, push('retired$i'));
        // Allow the second line to queue behind the blocked verifier.
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await c.connect('127.0.0.1', s.port);
      while (s.sockets.length < 5) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      for (final gate in gates.values) {
        gate.complete();
      }
      entered['liveA'] = Completer<void>();
      gates['liveA'] = Completer<void>();
      final delivered = c.pushes
          .where((event) => event['tag'] == 'liveC')
          .first;
      s.raw(4, push('liveA'));
      await entered['liveA']!.future;
      s.raw(4, push('liveB'));
      s.raw(4, push('liveC'));
      await Future<void>.delayed(const Duration(milliseconds: 25));
      gates['liveA']!.complete();
      await delivered.timeout(const Duration(seconds: 2));
      expect(c.isOpen, isTrue);
      expect(observed, ['liveA', 'liveB', 'liveC']);
    },
  );

  test(
    'explicit replacement fails old requests before reusing a request id',
    () async {
      final c = client();
      addTearDown(c.dispose);
      await c.connect('127.0.0.1', s.port);
      final old = c.request('history', reqId: 'id');
      final failed = expectLater(old, throwsStateError);
      await c.connect('127.0.0.1', s.port);
      await failed;
      expect((await c.request('ping', reqId: 'id'))['type'], 'pong');
    },
  );

  // T07: a throwing verifier must not stop the chain.
  test('T07 a failing verification does not stop later envelopes', () async {
    final c = client(
      verifier: (line) async {
        if (line.contains('"tag":"BOOM"')) {
          throw StateError('verifier exploded');
        }
        return ServerSigCheck.ok;
      },
    );
    await c.connect('127.0.0.1', s.port);
    final seen = collect(c);

    s.raw(0, push('BOOM'));
    s.raw(0, push('AFTER'));
    await Future.delayed(const Duration(milliseconds: 250));
    expect(seen, ['AFTER']);
    await c.dispose();
  });

  // ---------------- PART B: socket generation races ----------------

  // T08: the old socket's onDone fires after a new socket is installed and must
  // not tear the new one down.
  test(
    'T08 a late onDone of the old socket leaves the new socket alone',
    () async {
      final c = client();
      await c.connect('127.0.0.1', s.port);
      expect(c.isOpen, isTrue);

      // Kill the first socket, let the client build a second one.
      s.sockets[0].destroy();
      await Future.delayed(const Duration(seconds: 3));
      expect(
        s.sockets.length,
        greaterThanOrEqualTo(2),
        reason: 'the client should have reconnected',
      );
      expect(c.isOpen, isTrue);

      // Now the OLD socket's stream really finishes, late.
      try {
        s.sockets[0].destroy();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
      expect(
        c.isOpen,
        isTrue,
        reason: 'a stale onDone must not close the live connection',
      );
      await c.dispose();
    },
  );

  // T09 + T13: reconnecting is single-flight - exactly one extra connection.
  test('T09/T13 reconnect loop is not duplicated', () async {
    var attempts = 0;
    final c = GrchatConnection(
      connector: (h, p) {
        attempts++;
        return Socket.connect(h, p, timeout: const Duration(seconds: 5));
      },
    );
    await c.connect('127.0.0.1', s.port);
    expect(attempts, 1);

    s.sockets[0].destroy();
    // Backoff's first step is 1s; two loops would both fire inside this window.
    await Future.delayed(const Duration(milliseconds: 2500));
    expect(
      attempts,
      2,
      reason: 'exactly one reconnect attempt, no duplicate loops',
    );
    expect(c.isOpen, isTrue);
    await c.dispose();
  });

  // T10: a connector that resolves after dispose() installs nothing.
  test('T10 a connect resolving after dispose installs no socket', () async {
    final gate = Completer<void>();
    final c = GrchatConnection(
      connector: (h, p) async {
        await gate.future;
        return Socket.connect(h, p, timeout: const Duration(seconds: 5));
      },
    );
    final connecting = c.connect('127.0.0.1', s.port);
    await Future.delayed(const Duration(milliseconds: 50));
    await c.dispose();
    await Future.delayed(const Duration(milliseconds: 300));

    expect(
      c.isOpen,
      isFalse,
      reason: 'dispose must retire the generation for good',
    );
    gate.complete();
    await connecting.catchError((_) {});
    await Future.delayed(const Duration(milliseconds: 300));
    expect(
      c.isOpen,
      isFalse,
      reason: 'a connector that resolves late must install nothing',
    );
  });

  // T11: a late callback must not publish a status for the new connection.
  test('T11 a stale callback does not flip the live status', () async {
    final c = client();
    await c.connect('127.0.0.1', s.port);
    final states = <ConnStatus>[];
    c.status.listen(states.add);
    s.sockets[0].destroy();
    await Future.delayed(const Duration(seconds: 3));
    states.clear();

    // The retired socket finishing again must not announce anything.
    try {
      s.sockets[0].destroy();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));
    expect(
      states,
      isEmpty,
      reason: 'a stale socket must not publish status changes',
    );
    expect(c.isOpen, isTrue);
    await c.dispose();
  });

  // T12: pending requests of an old generation are not failed by a new socket.
  test('T12 old generation does not fail the new generation requests', () async {
    final c = client();
    await c.connect('127.0.0.1', s.port);

    // Attach the expectation BEFORE the teardown: a completer that fails while
    // nobody listens is reported as an unhandled async error.
    final first = c.request('ping', reqId: 'old');
    final firstFails = expectLater(first, throwsA(anything));
    s.sockets[0].destroy();
    await Future.delayed(const Duration(seconds: 3));
    await firstFails;

    // ...and a request on the NEW socket is unaffected by the old teardown.
    final second = c.request('ping', reqId: 'new');
    expect((await second)['type'], 'pong');
    await c.dispose();
  });

  // ---------------- PART C: pending requests ----------------

  // The fail-fast contract: an unsent request must not wait 15 seconds.
  test('a request without a connection fails immediately', () async {
    final c = client();
    final sw = Stopwatch()..start();
    await expectLater(
      c.request('call_offer', reqId: 'x'),
      throwsA(isA<NotConnectedException>()),
    );
    sw.stop();
    expect(
      sw.elapsedMilliseconds,
      lessThan(500),
      reason: 'must fail fast, not sit in the pending map until timeout',
    );
    await c.dispose();
  });

  test('dispose fails every outstanding request', () async {
    final c = client();
    await c.connect('127.0.0.1', s.port);
    final p = c.request('history', reqId: 'h1');
    final settled = expectLater(p, throwsStateError);
    await c.dispose();
    await settled;
  });
}
