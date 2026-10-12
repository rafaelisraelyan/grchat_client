import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Transport state for the UI banner.
enum ConnStatus { connected, connecting, offline }

/// Injectable socket factory for tests. Production always uses TLS.
typedef Connector = Future<Socket> Function(String host, int port);

/// Dev CA PEM path from `--dart-define=GRCHAT_DEV_CA=<path>`. Empty in
/// normal builds; only ever read in debug builds (see [shouldTrustDevCa]).
const _devCaFromDefine = String.fromEnvironment('GRCHAT_DEV_CA');

/// Pure decision: the dev CA is trusted only in a debug build with a path.
/// Release builds never trust it, whatever the define says.
bool shouldTrustDevCa({required bool isDebug, required String caPath}) =>
    isDebug && caPath.isNotEmpty;

/// Trust context with the dev CA added on top of the system roots, or null
/// when the dev CA must not be trusted (release, or no path given).
SecurityContext? devTrustContext(
    {required bool isDebug, required String caPath}) {
  if (!shouldTrustDevCa(isDebug: isDebug, caPath: caPath)) return null;
  final ctx = SecurityContext(withTrustedRoots: true);
  ctx.setTrustedCertificatesBytes(File(caPath).readAsBytesSync());
  return ctx;
}

/// One JSONL connection: 1 line = 1 JSON. Responses carry `req_id`,
/// server pushes don't. Matches responses to requests, exposes pushes.
///
/// TLS-only: every connection is a SecureSocket. Certificates are verified
/// by the platform trust store; `onBadCertificate` is always false. The dev
/// CA is an explicit debug-only addition (see [devTrustContext]).
///
/// Drops auto-reconnect with backoff (1/2/5/10/15/30s) until [dispose].
class GrchatConnection {
  GrchatConnection({
    Connector? connector,
    String devCaPath = _devCaFromDefine,
    bool isDebug = kDebugMode,
  }) : _connector = connector ??
            _secureConnector(devCaPath: devCaPath, isDebug: isDebug);

  final Connector _connector;

  static Connector _secureConnector(
          {required String devCaPath, required bool isDebug}) =>
      (host, port) => SecureSocket.connect(host, port,
          context: devTrustContext(isDebug: isDebug, caPath: devCaPath),
          onBadCertificate: (_) => false);

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
  Object? _lastConnectError;

  static const _backoff = [1, 2, 5, 10, 15, 30];

  Stream<Map<String, dynamic>> get pushes => _pushes.stream;
  Stream<ConnStatus> get status => _statusCtl.stream;
  bool get isOpen => _socket != null;

  /// First attempt is awaited and its failure is rethrown (certificate or
  /// handshake problems must reach the UI). Retries continue in background.
  Future<void> connect(String host, int port) async {
    _gen++;
    _manualClose = false;
    _host = host;
    _port = port;
    await _open();
    if (!isOpen) {
      _loop(_gen);
      final err = _lastConnectError;
      if (err != null) throw err;
    }
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
      _socket = await _connector(host, port);
      _lastConnectError = null;
    } catch (e) {
      _socket = null;
      _lastConnectError = e;
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
