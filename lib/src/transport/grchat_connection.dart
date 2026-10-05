import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Transport state for the UI banner.
enum ConnStatus { connected, connecting, offline }

/// One JSONL connection: 1 line = 1 JSON. Responses carry `req_id`,
/// server pushes don't. Matches responses to requests, exposes pushes.
///
/// Drops auto-reconnect with backoff (1/2/5/10/15/30s) until [dispose].
/// Re-auth and state resync live one layer up (see HomeState.resync).
class GrchatConnection {
  GrchatConnection({this.onBadCertificate});

  final bool Function(X509Certificate cert)? onBadCertificate;

  Socket? _socket;
  StreamSubscription<String>? _sub;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _pushes = StreamController<Map<String, dynamic>>.broadcast();
  final _statusCtl = StreamController<ConnStatus>.broadcast();
  Timer? _keepalive;
  var _seq = 0;
  var _gen = 0;
  var _manualClose = true;
  String? _host;
  int? _port;
  bool _tls = false;

  static const _backoff = [1, 2, 5, 10, 15, 30];

  Stream<Map<String, dynamic>> get pushes => _pushes.stream;
  Stream<ConnStatus> get status => _statusCtl.stream;
  bool get isOpen => _socket != null;

  Future<void> connect(String host, int port, {bool tls = false}) async {
    _gen++;
    _manualClose = false;
    _host = host;
    _port = port;
    _tls = tls;
    await _open();
    if (!isOpen) _loop(_gen);
  }

  /// Force an immediate reconnect attempt (banner retry button).
  Future<void> retryNow() async {
    if (_manualClose || _host == null || _port == null || isOpen) return;
    _gen++;
    await _open();
    if (!isOpen) _loop(_gen);
  }

  Future<void> _open() async {
    final host = _host;
    final port = _port;
    if (host == null || port == null) return;
    await _closeSocket();
    _statusCtl.add(ConnStatus.connecting);
    try {
      _socket = _tls
          ? await SecureSocket.connect(host, port,
              onBadCertificate: onBadCertificate ?? (_) => false)
          : await Socket.connect(host, port);
    } catch (_) {
      _socket = null;
      return;
    }
    _sub = _socket!
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone, onError: (_) => _onDone());
    _keepalive?.cancel();
    _keepalive = Timer.periodic(const Duration(seconds: 45), (_) {
      if (isOpen) {
        _send({'v': 1, 'type': 'ping', 'req_id': '__ka${_seq++}'});
      }
    });
    _statusCtl.add(ConnStatus.connected);
  }

  void _loop(int gen) async {
    var attempt = 0;
    while (!_manualClose && !isOpen && gen == _gen) {
      await Future.delayed(Duration(
          seconds: attempt < _backoff.length
              ? _backoff[attempt]
              : _backoff.last));
      if (_manualClose || isOpen || gen != _gen) return;
      attempt++;
      await _open();
    }
    if (!_manualClose && !isOpen && gen == _gen) {
      _statusCtl.add(ConnStatus.offline);
    }
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
    // Flip isOpen synchronously: _loop below checks it, and an awaited
    // cancel here would let _loop observe the stale non-null socket.
    final sub = _sub;
    _sub = null;
    _socket?.destroy();
    _socket = null;
    _keepalive?.cancel();
    _keepalive = null;
    if (sub != null) {
      // The done stream is finished; cancel outside this callback.
      Future.microtask(() async {
        try {
          await sub.cancel();
        } catch (_) {}
      });
    }
    if (!_manualClose) {
      _statusCtl.add(ConnStatus.connecting);
      _loop(_gen);
    }
  }

  Future<void> _closeSocket() async {
    _keepalive?.cancel();
    _keepalive = null;
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    _socket?.destroy();
    _socket = null;
  }

  Future<void> dispose() async {
    _gen++;
    _manualClose = true;
    await _closeSocket();
    _onDone();
  }
}
