import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';

void main() {
  test('ping/pong against local dev server', () async {
    final c = GrchatConnection();
    await c.connect('127.0.0.1', 8181);
    final r = await c.request('ping', reqId: 't1');
    expect(r['type'], 'pong');
    expect(r['req_id'], 't1');
    await c.dispose();
  });
}
