import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One JSONL connection: 1 line = 1 JSON. Responses carry `req_id`,
/// server pushes don't. Matches responses to requests, exposes pushes.
class GrchatConnection {
  GrchatConnection({this.onBadCertificate});

  final bool Function(X509Certificate cert)? onBadCertificate;

  Socket? _socket;
  StreamSubscription<String>? _sub;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _pushes = StreamController<Map<String, dynamic>>.broadcast();
  Timer? _keepalive;
  var _seq = 0;

  Stream<Map<String, dynamic>> get pushes => _pushes.stream;
  bool get isOpen => _socket != null;

  Future<void> connect(String host, int port, {bool tls = false}) async {
    await dispose();
    _socket = tls
        ? await SecureSocket.connect(host, port,
            onBadCertificate: onBadCertificate ?? (_) => false)
        : await Socket.connect(host, port);
    _sub = _socket!
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone, onError: (_) => _onDone());
    _keepalive = Timer.periodic(const Duration(seconds: 45), (_) {
      if (isOpen) {
        _send({'v': 1, 'type': 'ping', 'req_id': '__ka${_seq++}'});
      }
    });
  }

  Future<Map<String, dynamic>> request(String type,
      {String? reqId, Map<String, dynamic> fields = const {}}) {
    final id = reqId ?? 'r${_seq++}';
    final msg = <String, dynamic>{'v': 1, 'type': type, 'req_id': id}
      ..addAll(fields);
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _send(msg);
    return c.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('no response for $id');
    });
  }

  void _send(Map<String, dynamic> msg) {
    _socket?.write('${jsonEncode(msg)}\n');
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = msg['req_id']?.toString();
    final waiter = id == null ? null : _pending.remove(id);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(msg);
    } else {
      _pushes.add(msg);
    }
  }

  void _onDone() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('connection closed'));
    }
    _pending.clear();
  }

  Future<void> dispose() async {
    _keepalive?.cancel();
    _keepalive = null;
    await _sub?.cancel();
    _sub = null;
    _socket?.destroy();
    _socket = null;
    _onDone();
  }
}
