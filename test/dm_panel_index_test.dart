import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/app/providers.dart';
import 'package:grchat_client/src/app/theme.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/chat/file_api.dart';
import 'package:grchat_client/src/chat/home_state.dart';
import 'package:grchat_client/src/chat/models.dart';
import 'package:grchat_client/src/chat/widgets/dm_info_panel.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';

class _FakeSession extends SessionState {
  @override
  Session? build() =>
      Session(userId: 'u1', nick: 'Rafael', token: 't');
}

class _FakeHome extends HomeState {
  @override
  HomeData build() {
    final thread = DmThread(id: 'd1', isGroup: false, members: [
      DmMember(userId: 'u1', nick: 'Rafael'),
      DmMember(userId: 'u2', nick: 'Second'),
    ]);
    return HomeData(
      dms: [thread],
      scope: DmScope(thread, 'u1'),
      messages: const [],
      members: const [],
      loading: false,
    );
  }
}

AttachmentIndexEntry _entry(String id, String filename, String mime) =>
    AttachmentIndexEntry(
        attachmentId: id,
        fileId: 'f$id',
        filename: filename,
        mime: mime,
        sizeBytes: 100,
        messageId: 'm$id',
        createdAt: '2026-10-06T00:00:00Z');

class _FakeFiles extends FileApi {
  _FakeFiles()
      : super(GrchatConnection(),
            Session(userId: 'u1', nick: 'R', token: 't'));

  final calls = <String?>[];
  final pages = <AttachmentsIndex>[];

  @override
  Future<AttachmentsIndex> attachmentsIndex({
    String? dmId,
    String? channelId,
    String kind = 'all',
    int limit = 30,
    String? beforeId,
  }) async {
    calls.add(beforeId);
    return pages[calls.length - 1];
  }

  @override
  Future<Uint8List> download(String fileId) async {
    throw StateError('no bytes in tests');
  }
}

void main() {
  group('DmInfoPanel index', () {
    Future<_FakeFiles> pump(WidgetTester t) async {
      final files = _FakeFiles()
        ..pages.addAll([
          AttachmentsIndex(items: [
            _entry('a3', 'new.png', 'image/png'),
            _entry('a2', 'clip.mp4', 'video/mp4'),
            _entry('a1', 'doc.pdf', 'application/pdf'),
          ], hasMore: true),
          AttachmentsIndex(items: [
            _entry('a0', 'old.png', 'image/png'),
          ], hasMore: false),
        ]);
      await t.pumpWidget(ProviderScope(
          overrides: [
            sessionProvider.overrideWith(_FakeSession.new),
            homeStateProvider.overrideWith(_FakeHome.new),
            fileApiProvider.overrideWith((ref) => files),
          ],
          child: MaterialApp(
              theme: grchatLight,
              darkTheme: grchatDark,
              home: const Scaffold(body: DmInfoPanel()))));
      await t.pumpAndSettle();
      return files;
    }

    testWidgets('shows sections with server items', (t) async {
      await pump(t);
      expect(find.text('Фото'), findsOneWidget);
      expect(find.text('Файлы'), findsOneWidget);
      // Video rows carry filenames; image grid cells do not.
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(find.text('doc.pdf'), findsOneWidget);
      expect(find.text('Показать ещё'), findsOneWidget);
    });

    testWidgets('more button appends the next page', (t) async {
      final files = await pump(t);
      expect(files.calls, [null]);
      await t.tap(find.text('Показать ещё'));
      await t.pumpAndSettle();
      expect(files.calls, [null, 'a1']);
      expect(find.text('Показать ещё'), findsNothing);
      // Second page content merged in.
      expect(files.calls.length, 2);
    });
  });
}
