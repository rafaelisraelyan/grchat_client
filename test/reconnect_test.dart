import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';

void main() {
  test('reconnects after server drops the socket', () async {
    final server = await ServerSocket.bind('127.0.0.1', 0);
    final serverSides = <Socket>[];
    final sub = server.listen((s) {
      serverSides.add(s);
      s.listen((_) {}, onDone: () => s.destroy());
    });

    final conn = GrchatConnection();
    final seen = <ConnStatus>[];
    final statusSub = conn.status.listen(seen.add);

    await conn.connect('127.0.0.1', server.port);
    await Future.delayed(const Duration(milliseconds: 300));
    expect(conn.isOpen, isTrue);
    expect(seen, contains(ConnStatus.connected));
    seen.clear();
    final acceptedBefore = serverSides.length;

    // Drop every server-side socket; the client's pending read must fail,
    // which drives _onDone -> connecting -> backoff -> reconnect.
    for (final s in serverSides) {
      s.destroy();
    }

    final noticedDeadline =
        DateTime.now().add(const Duration(seconds: 12));
    while (!seen.contains(ConnStatus.connecting) &&
        DateTime.now().isBefore(noticedDeadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    // ignore: avoid_print
    print('after drop: isOpen=${conn.isOpen} seen=$seen '
        'sides=${serverSides.length}');
    expect(seen.contains(ConnStatus.connecting), isTrue,
        reason: 'client never noticed the server-side drop');

    final upDeadline = DateTime.now().add(const Duration(seconds: 15));
    while ((!conn.isOpen ||
            serverSides.length <= acceptedBefore) &&
        DateTime.now().isBefore(upDeadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    // ignore: avoid_print
    print('end: isOpen=${conn.isOpen} seen=$seen '
        'sides=${serverSides.length}');
    expect(conn.isOpen, isTrue);
    expect(serverSides.length, greaterThan(acceptedBefore));
    expect(seen, contains(ConnStatus.connected));

    await statusSub.cancel();
    await conn.dispose();
    await sub.cancel();
    await server.close();
  });
}
