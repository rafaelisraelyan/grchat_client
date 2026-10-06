import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/app/providers.dart';
import 'package:grchat_client/src/app/theme.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/call/call_state.dart';
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
      messages: [
        Message(
            id: 'm1',
            dmId: 'd1',
            authorId: 'u2',
            authorNick: 'Second',
            text: 'pic',
            createdAt: '2026-09-02T12:41:00Z',
            attachments: [
              Attachment(
                  fileId: 'f1',
                  filename: 'pic.png',
                  sizeBytes: 100,
                  mime: 'image/png')
            ]),
        Message(
            id: 'm2',
            dmId: 'd1',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'doc',
            createdAt: '2026-09-02T12:42:00Z',
            attachments: [
              Attachment(
                  fileId: 'f2',
                  filename: 'doc.pdf',
                  sizeBytes: 200,
                  mime: 'application/pdf')
            ]),
      ],
      members: const [],
      loading: false,
    );
  }
}

class _FakeCall extends CallState {
  String? lastPeer;
  bool? lastVideo;

  @override
  ActiveCall? build() => null;

  @override
  Future<void> startCall(
      {String? peerNick, String? dmId, required bool video}) async {
    lastPeer = peerNick;
    lastVideo = video;
  }
}

class _FakeFiles extends FileApi {
  _FakeFiles()
      : super(GrchatConnection(),
            Session(userId: 'u1', nick: 'R', token: 't'));

  @override
  Future<AttachmentsIndex> attachmentsIndex({
    String? dmId,
    String? channelId,
    String kind = 'all',
    int limit = 30,
    String? beforeId,
  }) async {
    return AttachmentsIndex(items: [
      AttachmentIndexEntry(
          attachmentId: 'a2',
          fileId: 'f2',
          filename: 'doc.pdf',
          mime: 'application/pdf',
          sizeBytes: 200,
          messageId: 'm2',
          createdAt: '2026-09-02T12:42:00Z'),
    ], hasMore: false);
  }

  @override
  Future<Uint8List> download(String fileId) async {
    throw StateError('no bytes in tests');
  }
}

void main() {
  group('DmInfoPanel', () {
    Future<_FakeCall> pump(WidgetTester t) async {
      final fake = _FakeCall();
      await t.pumpWidget(ProviderScope(
          overrides: [
            sessionProvider.overrideWith(_FakeSession.new),
            homeStateProvider.overrideWith(_FakeHome.new),
            callStateProvider.overrideWith(() => fake),
            fileApiProvider.overrideWith((ref) => _FakeFiles()),
          ],
          child: MaterialApp(
              theme: grchatLight,
              darkTheme: grchatDark,
              home: const Scaffold(body: DmInfoPanel()))));
      await t.pumpAndSettle();
      return fake;
    }

    testWidgets('shows profile, address and media', (t) async {
      await pump(t);
      expect(find.text('Second'), findsWidgets);
      expect(find.text('user/Second'), findsOneWidget);
      expect(find.text('Файлы'), findsOneWidget);
      expect(find.text('doc.pdf'), findsOneWidget);
      // No presence fiction and no members roster here.
      expect(find.textContaining('В СЕТИ'), findsNothing);
      expect(find.textContaining('был'), findsNothing);
    });

    testWidgets('audio and video buttons call the peer', (t) async {
      final fake = await pump(t);
      await t.tap(find.text('Аудио'));
      await t.pumpAndSettle();
      expect(fake.lastPeer, 'Second');
      expect(fake.lastVideo, isFalse);
      await t.tap(find.text('Видео'));
      await t.pumpAndSettle();
      expect(fake.lastVideo, isTrue);
    });

    testWidgets('call buttons expose semantics labels', (t) async {
      final handle = t.ensureSemantics();
      await pump(t);
      expect(find.bySemanticsLabel('Аудио'), findsOneWidget);
      expect(find.bySemanticsLabel('Видео'), findsOneWidget);
      handle.dispose();
    });
  });
}
