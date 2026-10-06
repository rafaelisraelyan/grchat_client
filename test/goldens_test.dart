import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/app/providers.dart';
import 'package:grchat_client/src/app/theme.dart';
import 'package:grchat_client/src/auth/auth_repository.dart';
import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/call_surface.dart';
import 'package:grchat_client/src/call/group_call.dart';
import 'package:grchat_client/src/call/group_call_window.dart';
import 'package:grchat_client/src/search/find_dialog.dart';
import 'package:grchat_client/src/search/search_address.dart';
import 'package:grchat_client/src/search/search_results.dart';
import 'package:grchat_client/src/auth/auth_screen.dart';
import 'package:grchat_client/src/chat/home_screen.dart';
import 'package:grchat_client/src/chat/widgets/members_panel.dart';
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

class _FakeHomeHover extends HomeState {  @override
  HomeData build() {
    return HomeData(
      communities: const [],
      activeCommunityId: null,
      dms: const [],
      scope: DmScope(
          DmThread(id: 'd1', isGroup: false, members: [
            DmMember(userId: 'u1', nick: 'Rafael'),
            DmMember(userId: 'u2', nick: 'Second'),
          ]),
          'u1'),
      messages: [
        Message(
            id: 'm1',
            dmId: 'd1',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'Моё сообщение',
            createdAt: '2026-09-02T12:41:00Z'),
      ],
      members: const [],
    );
  }
}

class _FakeHomeCalls extends HomeState {
  @override
  HomeData build() {
    final thread = DmThread(id: 'd1', isGroup: false, members: [
      DmMember(userId: 'u1', nick: 'Rafael'),
      DmMember(userId: 'u2', nick: 'Second'),
    ]);
    return HomeData(
      communities: const [],
      activeCommunityId: null,
      dms: [thread],
      scope: DmScope(thread, 'u1'),
      messages: [
        Message(
            id: 'c1',
            dmId: 'd1',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'Видеозвонок · 02:05',
            createdAt: '2026-09-02T12:40:00Z',
            kind: 'call',
            call: CallInfo(
                status: 'completed',
                durationSec: 125,
                video: true)),
        Message(
            id: 'c2',
            dmId: 'd1',
            authorId: 'u2',
            authorNick: 'Second',
            text: 'Пропущенный звонок',
            createdAt: '2026-09-02T12:50:00Z',
            kind: 'call',
            call: CallInfo(status: 'missed')),
        Message(
            id: 'c3',
            dmId: 'd1',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'Звонок отклонён',
            createdAt: '2026-09-02T13:00:00Z',
            kind: 'call',
            call: CallInfo(status: 'declined', endedBy: 'Second')),
        Message(
            id: 'c4',
            dmId: 'd1',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'Звонок · абонент не в сети',
            createdAt: '2026-09-02T13:10:00Z',
            kind: 'call',
            call: CallInfo(status: 'offline')),
      ],
      members: const [],
    );
  }
}

class _FakeHomeEmpty extends HomeState {
  @override
  HomeData build() {
    final thread = DmThread(id: 'd1', isGroup: false, members: [
      DmMember(userId: 'u1', nick: 'Rafael'),
      DmMember(userId: 'u2', nick: 'Second'),
    ]);
    return HomeData(
      communities: const [],
      activeCommunityId: null,
      dms: [thread],
      scope: DmScope(thread, 'u1'),
      messages: const [],
      members: const [],
      loading: false,
    );
  }
}

class _GoldenFindApi implements FindSearchApi {  _GoldenFindApi({this.hang = false, this.fail = false});
  final bool hang;
  final bool fail;

  @override
  Future<ServerHit> findServer(String alias) async {
    if (fail) throw GrchatException('NOT_FOUND');
    if (hang) await Completer<void>().future;
    return ServerHit(
        communityId: 'c1',
        name: 'GR Audio',
        alias: alias,
        isPrivate: false,
        membersCount: 423,
        isMember: false);
  }

  @override
  Future<ChannelHit> findChannel(String alias) async {
    if (fail) throw GrchatException('NOT_FOUND');
    if (hang) await Completer<void>().future;
    return ChannelHit(
        channelId: 'ch9',
        name: 'News',
        alias: alias,
        type: 'text',
        isPrivate: false,
        subscribersCount: 12,
        hasAccess: false);
  }

  @override
  Future<({String userId, String nick})> findUser(String nick) async {
    if (fail) throw GrchatException('NOT_FOUND');
    return (userId: 'u9', nick: nick);
  }
}

Future<void> _pumpFind(WidgetTester t, Widget dialog, ThemeMode mode) async {
  t.view.physicalSize = const Size(800, 600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(MaterialApp(
      theme: grchatLight,
      darkTheme: grchatDark,
      themeMode: mode,
      home: Scaffold(body: Center(child: dialog))));
  await t.pumpAndSettle();
}

FindDialog _findDialog(FindSearchApi api,
        {SearchTargetType initial = SearchTargetType.channel}) =>
    FindDialog(
      initialType: initial,
      search: api,
      onOpenServer: (_) async {},
      onOpenChannel: (_) async {},
      onWriteUser: (_) async {},
      onJoinServer: (_) async {},
      onSubscribeChannel: (_) async {},
    );

class _FakeHomeBroadcast extends HomeState {
  @override
  HomeData build() {
    final ch = Channel(
        id: 'ch9',
        name: 'Крутые вести',
        type: 'broadcast',
        alias: 'COOLNEWS',
        description: 'Новости проекта',
        role: 'owner',
        subscribersCount: 124);
    return HomeData(
      myChannels: [ch],
      scope: ChannelScope(null, ch),
      messages: [
        Message(
            id: 'p1',
            channelId: 'ch9',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'Выпустили новую версию приложения.',
            // September, not October: postTime renders "today"/"yesterday"
            // relative to the real clock, so October fixtures rot overnight
            // and the golden starts failing the next day. September dates
            // always take the stable DD.MM branch.
            createdAt: '2026-09-05T14:32:00Z',
            kind: 'post',
            attachments: [
              Attachment(
                  fileId: 'f9',
                  filename: 'release_notes.pdf',
                  sizeBytes: 2516582,
                  mime: 'application/pdf')
            ]),
        Message(
            id: 'p2',
            channelId: 'ch9',
            authorId: 'u1',
            authorNick: 'Rafael',
            text: 'Серверы обновятся ночью.',
            createdAt: '2026-09-04T18:00:00Z',
            editedAt: '2026-09-04T19:00:00Z',
            kind: 'post'),
      ],
      loading: false,
    );
  }
}

class _FakeHomeBroadcastEmpty extends HomeState {
  @override
  HomeData build() {
    final ch = Channel(
        id: 'ch9',
        name: 'Крутые вести',
        type: 'broadcast',
        alias: 'COOLNEWS',
        description: 'Новости проекта',
        role: 'member',
        subscribersCount: 124);
    return HomeData(
      myChannels: [ch],
      scope: ChannelScope(null, ch),
      messages: const [],
      loading: false,
    );
  }
}

class _FakeCallState extends CallState {
  _FakeCallState(this._c);
  final ActiveCall? _c;

  @override
  ActiveCall? build() => _c;
}

Future<void> _pumpCall(
    WidgetTester t, ActiveCall? call, ThemeMode mode) async {
  t.view.physicalSize = const Size(1280, 720);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(ProviderScope(
      overrides: [
        callStateProvider.overrideWith(() => _FakeCallState(call)),
      ],
      child: MaterialApp(
          theme: grchatLight,
          darkTheme: grchatDark,
          themeMode: mode,
          home: const Scaffold(
              body: Stack(children: [
            Positioned.fill(
                child: ColoredBox(color: Color(0xFF1A1A22))),
            CallOverlayHost(),
          ])))));
  // Fixed frames: the active-call timer is periodic, settle would hang.
  await t.pump();
  await t.pump(const Duration(seconds: 1));
  await t.pump();
}

ActiveCall _goldenCall(
        {bool outgoing = false,
        bool video = false,
        CallPhase phase = CallPhase.ringing,
        bool remoteVideo = false,
        bool minimized = false}) =>
    ActiveCall(
        callId: 'c1',
        peerNick: 'Masha',
        video: video,
        outgoing: outgoing,
        phase: phase,
        remoteVideo: remoteVideo,
        minimized: minimized);

class _FakeGroupCall extends GroupCallState {
  _FakeGroupCall(this._c);
  final GroupCall? _c;

  @override
  GroupCall? build() => _c;
}

Future<void> _pumpGroup(
    WidgetTester t, GroupCall? call, ThemeMode mode) async {
  t.view.physicalSize = const Size(1280, 720);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(ProviderScope(
      overrides: [
        groupCallProvider.overrideWith(() => _FakeGroupCall(call)),
      ],
      child: MaterialApp(
          theme: grchatLight,
          darkTheme: grchatDark,
          themeMode: mode,
          home: const Scaffold(
              body: Stack(children: [
            Positioned.fill(
                child: ColoredBox(color: Color(0xFF1A1A22))),
            GroupCallHost(),
          ])))));
  await t.pumpAndSettle();
}

GroupCall _goldenGroup(
        {bool outgoing = false,
        bool video = true,
        GroupPhase phase = GroupPhase.ringing,
        List<GroupPeer> peers = const []}) =>
    GroupCall(
        dmId: 'd9',
        title: 'Команда',
        room: 'grchat_d9',
        video: video,
        outgoing: outgoing,
        phase: phase,
        callId: 'k9',
        peers: peers);

class _FakeHomeDmProfile extends HomeState {
  @override
  HomeData build() {
    final thread = DmThread(id: 'd1', isGroup: false, members: [
      DmMember(userId: 'u1', nick: 'Rafael'),
      DmMember(userId: 'u2', nick: 'Second'),
    ]);
    return HomeData(
      communities: const [],
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
                  sizeBytes: 1258291,
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
                  filename: 'notes.pdf',
                  sizeBytes: 860160,
                  mime: 'application/pdf')
            ]),
      ],
      members: const [],
      loading: false,
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
    // Real decode, not fake-async: otherwise the logo may not be ready.
    await t.runAsync(() async {
      final el =
          t.element(find.byType(Image).first);
      await precacheImage(
          const AssetImage('assets/logo-icon.png'), el);
    });
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

  testWidgets('call records', (t) async {    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHomeCalls.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    await expectLater(
        find.byType(HomeScreen),
        matchesGoldenFile('goldens/call_records.png'));
  });

  testWidgets('empty chat', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHomeEmpty.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    await expectLater(
        find.byType(HomeScreen),
        matchesGoldenFile('goldens/empty_chat.png'));
  });

  testWidgets('home narrow hides members', (t) async {
    t.view.physicalSize = const Size(1000, 700);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHome.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    expect(find.byType(MembersPanel), findsNothing);
    await expectLater(
        find.byType(HomeScreen), matchesGoldenFile('goldens/home_narrow.png'));
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

  testWidgets('own message hover actions', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHomeHover.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    final g = await t.createGesture(kind: ui.PointerDeviceKind.mouse);
    await g.addPointer();
    await g.moveTo(t.getCenter(find.text('Моё сообщение')));
    // Settle, not a single pump: the hover fade-in needs ticker frames.
    await t.pumpAndSettle();
    await expectLater(
        find.byType(HomeScreen), matchesGoldenFile('goldens/hover.png'));
    // hover toolbar opens inline editing (banner), not a dialog
    await t.tap(find.byIcon(Icons.edit));
    await t.pumpAndSettle();
    expect(find.text('Редактирование'), findsOneWidget);
    expect(find.text('Моё сообщение'), findsWidgets);
    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();
    expect(find.text('Редактирование'), findsNothing);
    // delete opens a confirm
    await g.moveTo(t.getCenter(find.text('Моё сообщение').first));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byIcon(Icons.delete));
    await t.pumpAndSettle();
    expect(find.text('Удалить сообщение?'), findsOneWidget);
    await t.tap(find.text('Отмена'));
    await t.pumpAndSettle();
    await g.removePointer();
  });

  testWidgets('double click edits own message', (t) async {    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHomeHover.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    await t.tap(find.text('Моё сообщение'));
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(find.text('Моё сообщение'));
    await t.pumpAndSettle();
    expect(find.text('Редактирование'), findsOneWidget);
  });

  testWidgets('find dialog dark', (t) async {
    await _pumpFind(t, _findDialog(_GoldenFindApi()), ThemeMode.dark);
    await expectLater(
        find.byType(FindDialog), matchesGoldenFile('goldens/find_dark.png'));
  });

  testWidgets('find dialog light server', (t) async {
    await _pumpFind(
        t,
        _findDialog(_GoldenFindApi(),
            initial: SearchTargetType.server),
        ThemeMode.light);
    await expectLater(find.byType(FindDialog),
        matchesGoldenFile('goldens/find_light.png'));
  });

  testWidgets('find dialog bot inactive', (t) async {
    await _pumpFind(
        t,
        _findDialog(_GoldenFindApi(), initial: SearchTargetType.bot),
        ThemeMode.dark);
    await expectLater(find.byType(FindDialog),
        matchesGoldenFile('goldens/find_bot.png'));
  });

  testWidgets('find dialog result', (t) async {
    await _pumpFind(t, _findDialog(_GoldenFindApi()), ThemeMode.dark);
    await t.enterText(find.byType(TextField), 'NEWS');
    await t.tap(find.text('Найти'));
    await t.pumpAndSettle();
    await expectLater(find.byType(FindDialog),
        matchesGoldenFile('goldens/find_result.png'));
  });

  testWidgets('find dialog not found', (t) async {
    await _pumpFind(
        t, _findDialog(_GoldenFindApi(fail: true)), ThemeMode.dark);
    await t.enterText(find.byType(TextField), 'NOPE');
    await t.tap(find.text('Найти'));
    await t.pumpAndSettle();
    await expectLater(find.byType(FindDialog),
        matchesGoldenFile('goldens/find_not_found.png'));
  });

  testWidgets('find dialog loading', (t) async {
    await _pumpFind(
        t, _findDialog(_GoldenFindApi(hang: true)), ThemeMode.dark);
    await t.enterText(find.byType(TextField), 'NEWS');
    await t.tap(find.text('Найти'));
    await t.pump();
    await expectLater(find.byType(FindDialog),
        matchesGoldenFile('goldens/find_loading.png'));
  });

  testWidgets('broadcast feed dark', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHomeBroadcast.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    await expectLater(find.byType(HomeScreen),
        matchesGoldenFile('goldens/feed_dark.png'));
  });

  testWidgets('broadcast feed empty subscriber', (t) async {    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(
              _FakeHomeBroadcastEmpty.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    await expectLater(find.byType(HomeScreen),
        matchesGoldenFile('goldens/feed_empty.png'));
  });

  testWidgets('call incoming dark', (t) async {
    await _pumpCall(
        t,
        _goldenCall(video: false),
        ThemeMode.dark);
    await expectLater(find.byType(CallOverlayHost),
        matchesGoldenFile('goldens/call_incoming.png'));
  });

  testWidgets('call incoming light', (t) async {
    await _pumpCall(
        t,
        _goldenCall(video: true),
        ThemeMode.light);
    await expectLater(find.byType(CallOverlayHost),
        matchesGoldenFile('goldens/call_incoming_light.png'));
  });

  testWidgets('call outgoing dark', (t) async {
    await _pumpCall(
        t,
        _goldenCall(outgoing: true, video: false),
        ThemeMode.dark);
    await expectLater(find.byType(CallOverlayHost),
        matchesGoldenFile('goldens/call_outgoing.png'));
  });

  testWidgets('call active audio dark', (t) async {
    await _pumpCall(
        t,
        _goldenCall(
            outgoing: true, video: false, phase: CallPhase.active),
        ThemeMode.dark);
    await expectLater(find.byType(CallOverlayHost),
        matchesGoldenFile('goldens/call_audio.png'));
  });

  testWidgets('call active video placeholder dark', (t) async {
    await _pumpCall(
        t,
        _goldenCall(
            outgoing: true, video: true, phase: CallPhase.active),
        ThemeMode.dark);
    await expectLater(find.byType(CallOverlayHost),
        matchesGoldenFile('goldens/call_video_wait.png'));
  });

  testWidgets('call mini overlay dark', (t) async {
    await _pumpCall(
        t,
        _goldenCall(
            outgoing: true,
            video: false,
            phase: CallPhase.active,
            minimized: true),
        ThemeMode.dark);
    await expectLater(find.byType(CallOverlayHost),
        matchesGoldenFile('goldens/call_mini.png'));
  });

  testWidgets('group incoming dark', (t) async {
    await _pumpGroup(
        t, _goldenGroup(video: true), ThemeMode.dark);
    await expectLater(find.byType(GroupCallHost),
        matchesGoldenFile('goldens/group_incoming.png'));
  });

  testWidgets('group incoming light', (t) async {
    await _pumpGroup(
        t, _goldenGroup(video: false), ThemeMode.light);
    await expectLater(find.byType(GroupCallHost),
        matchesGoldenFile('goldens/group_incoming_light.png'));
  });

  testWidgets('group active grid dark', (t) async {    await _pumpGroup(
        t,
        _goldenGroup(
            outgoing: true,
            video: true,
            phase: GroupPhase.active,
            peers: [
              GroupPeer(
                  identity: 'u2',
                  name: 'Second',
                  videoTrack: null,
                  audioMuted: false),
              GroupPeer(
                  identity: 'u3',
                  name: 'TestPilot',
                  videoTrack: null,
                  audioMuted: true),
            ]),
        ThemeMode.dark);
    await expectLater(find.byType(GroupCallHost),
        matchesGoldenFile('goldens/group_active.png'));
  });

  testWidgets('dm profile panel dark', (t) async {    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHomeDmProfile.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    await expectLater(find.byType(HomeScreen),
        matchesGoldenFile('goldens/dm_profile.png'));
  });

  testWidgets('quick nav palette dark', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_FakeSession.new),
          homeStateProvider.overrideWith(_FakeHome.new),
        ],
        child: MaterialApp(
            theme: grchatLight,
            darkTheme: grchatDark,
            themeMode: ThemeMode.dark,
            home: const HomeScreen())));
    await t.pumpAndSettle();
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyK);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pumpAndSettle();
    if (find.text('Перейти').evaluate().isEmpty) {
      // Key-event dispatch can be flaky: retry once.
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyK);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();
    }
    expect(find.text('Перейти'), findsOneWidget);
    // Capture the whole app: the dialog lives in the Overlay,
    // outside HomeScreen's render tree.
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/quick_nav.png'));
  });
}
