import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../call/call_diagnostics.dart';
import 'server_sign.dart';

/// Transport state for the UI banner.
enum ConnStatus { connected, connecting, offline }

/// Injectable socket factory for tests. Production always uses TLS.
typedef Connector = Future<Socket> Function(String host, int port);

/// Injectable envelope signature check. Production is [checkServerEnvelopeSig];
/// tests inject a verifier so the (asynchronous) verification step can be made
/// deterministically slow. The Ed25519 policy itself is never relaxed here -
/// only WHERE it is called from.
typedef EnvelopeVerifier = Future<ServerSigCheck> Function(String line);

/// Raised by [GrchatConnection.request] when there is no live socket.
///
/// Deliberately immediate: a request that could not even be written must not sit
/// in the pending map until the 15s timeout, and must never look like a server
/// that is merely slow.
class NotConnectedException implements Exception {
  NotConnectedException(this.reason);
  final String reason;

  @override
  String toString() => 'NotConnectedException: $reason';
}

/// Dev CA PEM path from `--dart-define=GRCHAT_DEV_CA=<path>`. Empty in
/// normal builds; only ever read in debug builds (see [shouldTrustDevCa]).
const _devCaFromDefine = String.fromEnvironment('GRCHAT_DEV_CA');

/// Pure decision: the dev CA is trusted only in a debug build with a path.
/// Release builds never trust it, whatever the define says.
bool shouldTrustDevCa({required bool isDebug, required String caPath}) =>
    isDebug && caPath.isNotEmpty;

/// Trust context with the dev CA added on top of the system roots, or null
/// when the dev CA must not be trusted (release, or no path given).
SecurityContext? devTrustContext({
  required bool isDebug,
  required String caPath,
}) {
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
///
/// Stage 2B invariants this class now guarantees:
///  * inbound envelopes of ONE socket are verified and routed strictly in
///    arrival order (verification is async, so they are chained, never
///    fanned out);
///  * every callback is bound to the socket identity it belongs to, so a late
///    [Socket.onDone] of an old socket can never tear down a newer one;
///  * at most ONE reconnect loop runs per connection generation;
///  * a request that cannot be written fails immediately.
class GrchatConnection {
  GrchatConnection({
    Connector? connector,
    EnvelopeVerifier? verifier,
    String devCaPath = _devCaFromDefine,
    bool isDebug = kDebugMode,
    this.maxQueuedEnvelopes = 512,
  }) : _connector =
           connector ??
           _secureConnector(devCaPath: devCaPath, isDebug: isDebug),
       _verifier = verifier ?? checkServerEnvelopeSig;

  final Connector _connector;
  final EnvelopeVerifier _verifier;

  /// Inbound envelope backstop (§29). Signalling order cannot be preserved by
  /// discarding an arbitrary line, so an overflow drops the CONNECTION and lets
  /// the normal recovery path resynchronise - it never silently drops a call
  /// event in the middle of a conversation.
  final int maxQueuedEnvelopes;

  static Connector _secureConnector({
    required String devCaPath,
    required bool isDebug,
  }) =>
      (host, port) => SecureSocket.connect(
        host,
        port,
        context: devTrustContext(isDebug: isDebug, caPath: devCaPath),
        onBadCertificate: (_) => false,
      );

  Socket? _socket;
  StreamSubscription<String>? _sub;
  final _pending = <String, _PendingReq>{};
  final _pushes = StreamController<Map<String, dynamic>>.broadcast();
  final _statusCtl = StreamController<ConnStatus>.broadcast();
  Timer? _keepalive;
  var _seq = 0;

  /// Bumped by every [connect]/[retryNow]: retires loops and in-flight opens.
  var _gen = 0;

  /// Bumped every time a socket is installed: identifies one TCP connection.
  var _socketGen = 0;
  _InboundQueue? _inbound;
  int? _reconnectGeneration;
  var _manualClose = true;
  String? _host;
  int? _port;
  Object? _lastConnectError;

  static const _backoff = [1, 2, 5, 10, 15, 30];

  Stream<Map<String, dynamic>> get pushes => _pushes.stream;
  Stream<ConnStatus> get status => _statusCtl.stream;
  bool get isOpen => _socket != null;

  /// Connection generation of the live socket; 0 when nothing is open. Exposed
  /// for diagnostics and for the resume flow, which must not act on a socket
  /// that has already been retired.
  int get socketGeneration => isOpen ? _socketGen : 0;

  /// First attempt is awaited and its failure is rethrown (certificate or
  /// handshake problems must reach the UI). Retries continue in background.
  Future<void> connect(String host, int port) async {
    final generation = ++_gen;
    _manualClose = false;
    _host = host;
    _port = port;
    await _open(generation);
    if (!_manualClose && generation == _gen && !isOpen) {
      _ensureLoop(generation);
      final err = _lastConnectError;
      if (err != null) throw err;
    }
  }

  /// Force an immediate reconnect attempt (banner retry button).
  Future<void> retryNow() async {
    if (_manualClose || _host == null || _port == null || isOpen) return;
    final generation = ++_gen;
    await _open(generation);
    _ensureLoop(generation);
  }

  Future<void> _open(int gen) async {
    final host = _host;
    final port = _port;
    if (host == null || port == null || gen != _gen || _manualClose) return;
    await _closeSocket();
    // A newer connect()/retryNow() may have retired this generation while the
    // connector was in flight; from here on this attempt owns nothing.
    if (_manualClose || gen != _gen) return;
    _statusCtl.add(ConnStatus.connecting);
    final Socket sock;
    try {
      sock = await _connector(host, port);
    } catch (e) {
      if (gen == _gen) {
        _socket = null;
        _lastConnectError = e;
      }
      return;
    }
    // A connector that resolves LATE must never replace a newer connection.
    if (_manualClose || gen != _gen) {
      try {
        sock.destroy();
      } catch (_) {}
      return;
    }
    _socket = sock;
    _socketGen++;
    final inbound = _InboundQueue();
    _inbound = inbound;
    _sub = sock
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _onLine(sock, inbound, line),
          onDone: () => _onDone(sock),
          onError: (_) => _onDone(sock),
        );
    _keepalive?.cancel();
    _keepalive = Timer.periodic(const Duration(seconds: 45), (_) {
      final s = _socket;
      if (s != null) {
        _send(s, {'v': 1, 'type': 'ping', 'req_id': '__ka${_seq++}'});
      }
    });
    _lastConnectError = null;
    _statusCtl.add(ConnStatus.connected);
  }

  /// At most one reconnect loop per generation: [connect], [retryNow] and
  /// [_onDone] all reach this point, and two of them racing used to leave two
  /// loops fighting over the same socket slot.
  void _ensureLoop(int gen) {
    if (_manualClose || isOpen || gen != _gen || _reconnectGeneration == gen) {
      return;
    }
    _reconnectGeneration = gen;
    _loop(gen);
  }

  void _loop(int gen) async {
    var attempt = 0;
    try {
      while (!_manualClose && !isOpen && gen == _gen) {
        await Future.delayed(
          Duration(
            seconds: attempt < _backoff.length
                ? _backoff[attempt]
                : _backoff.last,
          ),
        );
        if (_manualClose || isOpen || gen != _gen) return;
        attempt++;
        await _open(gen);
      }
      if (!_manualClose && !isOpen && gen == _gen) {
        _statusCtl.add(ConnStatus.offline);
      }
    } finally {
      if (_reconnectGeneration == gen) _reconnectGeneration = null;
    }
  }

  Future<Map<String, dynamic>> request(
    String type, {
    String? reqId,
    Map<String, dynamic> fields = const {},
  }) {
    final sock = _socket;
    if (sock == null) {
      // Fail fast: an unsent request must not masquerade as a slow server.
      return Future.error(
        NotConnectedException('cannot send "$type": no live connection'),
      );
    }
    final id = reqId ?? 'r${_seq++}';
    final msg = <String, dynamic>{'v': 1, 'type': type, 'req_id': id}
      ..addAll(fields);
    if (_pending.containsKey(id)) {
      return Future.error(StateError('request already pending: $id'));
    }
    final c = Completer<Map<String, dynamic>>();
    // The generation is recorded so a socket teardown only fails the requests
    // that belonged to IT - never the ones a newer socket is now carrying.
    final pending = _PendingReq(c, _socketGen);
    _pending[id] = pending;
    if (!_send(sock, msg)) {
      _pending.remove(id);
      return Future.error(
        NotConnectedException('connection dropped before "$type" was sent'),
      );
    }
    return c.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        if (identical(_pending[id], pending)) _pending.remove(id);
        throw TimeoutException('no response for $id');
      },
    );
  }

  bool _send(Socket sock, Map<String, dynamic> msg) {
    try {
      sock.write('${jsonEncode(msg)}\n');
      return true;
    } catch (e) {
      return false;
    }
  }

  void _onLine(Socket sock, _InboundQueue inbound, String line) {
    if (!identical(inbound, _inbound) || line.trim().isEmpty) return;
    if (inbound.queued >= maxQueuedEnvelopes) {
      dlog('inbound queue overflow (${inbound.queued}) - dropping connection');
      _onDone(sock);
      return;
    }
    final gen = _socketGen;
    inbound.queued++;
    // Each socket owns a serial chain so an old verifier cannot stall or
    // consume the budget of its replacement.
    inbound.tail = inbound.tail.then((_) async {
      try {
        await _dispatch(inbound, gen, line);
      } finally {
        inbound.queued--;
      }
    });
  }

  bool _sigAbsentLogged = false;

  /// Signature gate sits before ANY dispatch (§server_sign): a line that
  /// carries a signature but fails verification is dropped whole - it must
  /// never reach a response matcher or the push stream.
  Future<void> _dispatch(_InboundQueue inbound, int gen, String line) async {
    if (!identical(inbound, _inbound)) return;
    try {
      final check = await _verifier(line);
      if (!identical(inbound, _inbound)) return; // retired mid-verify
      switch (check) {
        case ServerSigCheck.bad:
          dlog('server envelope signature check failed - line dropped');
          return;
        case ServerSigCheck.absent:
          if (!_sigAbsentLogged && kDebugMode) {
            _sigAbsentLogged = true;
            dlog('server envelope unsigned (GRCHAT_SIGN_SEED off?)');
          }
        case ServerSigCheck.ok:
          break;
      }
      Map<String, dynamic> msg;
      try {
        msg = jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      final id = msg['req_id']?.toString();
      final waiter = id == null ? null : _pending.remove(id);
      if (waiter != null && !waiter.completer.isCompleted) {
        // Only complete a request that belongs to THIS generation; a late
        // answer from a retired socket must not satisfy a newer request.
        if (waiter.gen == gen) {
          waiter.completer.complete(msg);
        }
      } else {
        _pushes.add(msg);
      }
    } catch (e) {
      // A decode/verify failure must not stall the ordered chain.
      dlog('envelope dispatch failed - dropped: ${e.runtimeType}');
    }
  }

  /// Bound to the socket that produced it: a late `onDone` from an OLD socket
  /// must not clear the new socket, fail its pending requests or start a second
  /// reconnect loop.
  void _onDone(Socket sock) {
    if (!identical(sock, _socket)) return;
    unawaited(_closeSocket());
    if (!_manualClose) {
      _statusCtl.add(ConnStatus.connecting);
      _ensureLoop(_gen);
    }
  }

  Future<void> _closeSocket() async {
    final sock = _socket;
    final sub = _sub;
    // Detach all state before any await or socket callback.
    _socket = null;
    _sub = null;
    _inbound = null;
    _keepalive?.cancel();
    _keepalive = null;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      request.completer.completeError(StateError('connection closed'));
    }
    try {
      sock?.destroy();
      await sub?.cancel();
    } catch (error) {
      dlog('socket teardown failed: ${error.runtimeType}');
    }
  }

  Future<void> dispose() async {
    _gen++;
    _manualClose = true;
    await _closeSocket();
  }
}

class _InboundQueue {
  Future<void> tail = Future<void>.value();
  int queued = 0;
}

class _PendingReq {
  _PendingReq(this.completer, this.gen);
  final Completer<Map<String, dynamic>> completer;
  final int gen;
}
