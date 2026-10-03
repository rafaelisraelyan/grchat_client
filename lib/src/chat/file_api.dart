import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../auth/auth_repository.dart';
import '../transport/grchat_connection.dart';

const _chunkSize = 24576;

/// File upload (offer/chunk/commit) and download (begin/data/end) .
class FileApi {
  FileApi(this._conn, this._session);
  final GrchatConnection _conn;
  final Session _session;

  Map<String, String> get _auth => {'session_token': _session.token};

  void _throwIfError(Map<String, dynamic> r) {
    if (r['type'] == 'error') {
      throw GrchatException(r['code']?.toString() ?? 'UNKNOWN', r);
    }
  }

  Future<void> upload({
    required String? channelId,
    required String? dmId,
    required String filename,
    required Uint8List bytes,
    required String mime,
    String text = '',
    void Function(double progress)? onProgress,
  }) async {
    final scope = channelId != null
        ? {'channel_id': channelId}
        : {'dm_id': dmId};
    final offer = await _conn.request('file_offer', fields: {
      ..._auth,
      ...scope,
      'filename': filename,
      'size_bytes': bytes.length,
      'mime': mime,
    });
    _throwIfError(offer);
    final fileId = offer['file_id'] as String;
    try {
      final total = (bytes.length + _chunkSize - 1) ~/ _chunkSize;
      for (var i = 0; i < total; i++) {
        final from = i * _chunkSize;
        final to = (from + _chunkSize).clamp(0, bytes.length);
        final r = await _conn.request('file_chunk', fields: {
          ..._auth,
          'file_id': fileId,
          'index': i,
          'data': base64Encode(bytes.sublist(from, to)),
        });
        _throwIfError(r);
        onProgress?.call((i + 1) / total);
      }
      final done = await _conn.request('file_commit',
          fields: {..._auth, 'file_id': fileId, 'text': text});
      _throwIfError(done);
    } catch (e) {
      try {
        await _conn.request('file_abort',
            fields: {..._auth, 'file_id': fileId});
      } catch (_) {}
      rethrow;
    }
  }

  Future<Uint8List> download(String fileId) async {
    final chunks = <int, List<int>>{};
    int? total;
    final done = Completer<void>();
    final sub = _conn.pushes.listen((m) {
      if (m['file_id'] != fileId) return;
      if (m['type'] == 'file_data') {
        chunks[m['index'] as int] =
            base64Decode(m['data'] as String);
        final t = total;
        if (t != null && chunks.length >= t) {
          if (!done.isCompleted) done.complete();
        }
      }
    });
    try {
      final begin = await _conn.request('file_get',
          fields: {..._auth, 'file_id': fileId});
      _throwIfError(begin);
      total = (begin['total_chunks'] as num).toInt();
      if (total == 0) return Uint8List(0);
      if (chunks.length >= total) {
        if (!done.isCompleted) done.complete();
      }
      await done.future.timeout(const Duration(seconds: 60));
      final out = BytesBuilder();
      for (var i = 0; i < total; i++) {
        out.add(chunks[i] ?? Uint8List(0));
      }
      return out.toBytes();
    } finally {
      await sub.cancel();
    }
  }
}
