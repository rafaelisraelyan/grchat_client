import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/app/providers.dart';
import 'package:grchat_client/src/app/theme.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/auth/auth_screen.dart';
import 'package:grchat_client/src/chat/home_screen.dart';
import 'package:grchat_client/src/chat/home_state.dart';
import 'package:grchat_client/src/chat/models.dart';

import 'package:grchat_client/src/settings/settings_screen.dart';

class _FakeSession extends SessionState {
  @override
  Session? build() =>
      Session(userId: 'u1', nick: 'Rafael', token: 't');
}

class _FakeHome extends HomeState {
  @override
  HomeData build() {
    final comm = Community(id: 'c1', name: 'My server', role: 'owner', channels: [
      Channel(id: 'ch1', name: 'general', type: 'text'),
      Channel(id: 'ch2', name: 'announce', type: 'text'),
      Channel(id: 'ch3', name: 'voice', type: 'voice'),
    ]);
    return HomeData(
      communities: [comm],
      activeCommunityId: 'c1',
      dms: [        DmThread(id: 'd1', isGroup: false, members: [
          DmMember(userId: 'u1', nick: 'Rafael'),
          DmMember(userId: 'u2', nick: 'Second'),
        ], lastText: 'Привет!'),
      ],
      scope: ChannelScope(comm, comm.channels.first),
      messages: [
        Message(
            id: 'm0',
            channelId: 'ch1',
            authorId: 'u2',
            authorNick: 'Second',
            text: 'Вчерашний вопрос',
            createdAt: '2026-09-01T20:10:00Z'),
        Message(
            id: 'm1',
            channelId: 'ch1',
            authorId: 'u2',
            authorNick: 'Second',
            text: 'Привет! Видишь вложения?',
            createdAt: '2026-09-02T12:41:00Z'),
        Message(
            id: 'm1b',
            channelId: 'ch1',
            authorId: 'u2',
            authorNick: 'Second',
            text: 'Я сейчас закончу работу.',
            createdAt: '2026-09-02T12:42:00Z'),
        Message(
            id: 'm2',
            channelId: 'ch1',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'Вижу',
            createdAt: '2026-09-02T12:43:00Z',
            attachments: [
              Attachment(
                  fileId: 'f1',
                  filename: 'pic.png',
                  sizeBytes: 1258291,
                  mime: 'image/png')
            ]),
      ],
      members: [
        Member(userId: 'u1', nick: 'Rafael', role: 'owner'),
        Member(userId: 'u2', nick: 'Second', role: 'mod'),
      ],
    );
  }
}

class _FakeHomeDm extends HomeState {
  @override
  HomeData build() {
    return HomeData(
      communities: const [],
      dms: [
        DmThread(id: 'd1', isGroup: false, members: [
          DmMember(userId: 'u1', nick: 'Rafael'),
          DmMember(userId: 'u2', nick: 'Second'),
        ], lastText: 'Привет!'),
        DmThread(id: 'd2', isGroup: true, members: [
          DmMember(userId: 'u1', nick: 'Rafael'),
          DmMember(userId: 'u2', nick: 'Second'),
          DmMember(userId: 'u3', nick: 'TestPilot'),
        ]),
      ],
      scope: DmScope(
          DmThread(id: 'd1', isGroup: false, members: [
            DmMember(userId: 'u1', nick: 'Rafael'),
            DmMember(userId: 'u2', nick: 'Second'),
          ]),
          'u1'),
      messages: [
        Message(
            id: 'm9',
            dmId: 'd1',
            authorId: 'u2',
            authorNick: 'Second',
            text: 'Это личка',
            createdAt: ''),
      ],
      members: [
        Member(userId: 'u1', nick: 'Rafael', role: ''),
        Member(userId: 'u2', nick: 'Second', role: ''),
      ],
    );
  }
}

void main() {
  testWidgets('auth screen', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(const ProviderScope(
        child: MaterialApp(home: AuthScreen())));
    await t.pumpAndSettle();
    await expectLater(
        find.byType(AuthScreen), matchesGoldenFile('goldens/auth.png'));
  });

  testWidgets('home screen dark', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHome.new),
        ],
        child: MaterialApp(
            theme: grchatLight, darkTheme: grchatDark, themeMode: ThemeMode.dark, home: const HomeScreen())));
    await t.pumpAndSettle();
    await expectLater(
        find.byType(HomeScreen), matchesGoldenFile('goldens/home_dark.png'));
  });

  testWidgets('home dm stand', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHomeDm.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    await expectLater(
        find.byType(HomeScreen), matchesGoldenFile('goldens/home_dm.png'));
  });

  testWidgets('settings', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const SettingsScreen())));
    await t.pumpAndSettle();
    await expectLater(find.byType(SettingsScreen),
        matchesGoldenFile('goldens/settings.png'));
  });
}
