import 'dart:async';
import 'dart:typed_data';

import 'package:riverpod/riverpod.dart';

import '../app/providers.dart';
import 'chat_repository.dart';
import 'file_api.dart';
import 'models.dart';

/// Selected conversation: channel or DM thread.
abstract class Scope {
  String get key;
  String get title;
}

class ChannelScope implements Scope {
  ChannelScope(this.community, this.channel);
  final Community community;
  final Channel channel;

  @override
  String get key => 'c:${channel.id}';
  @override
  String get title => '# ${channel.name}';
}

class DmScope implements Scope {
  DmScope(this.thread, this.myId);
  final DmThread thread;
  final String myId;

  @override
  String get key => 'd:${thread.id}';
  @override
  String get title => thread.title(myId);
}

class HomeData {
  const HomeData({
    this.communities = const [],
    this.dms = const [],
    this.activeCommunityId,
    this.scope,
    this.messages = const [],
    this.members = const [],
    this.typing = const {},
    this.unread = const {},
    this.loading = true,
    this.error,
  });

  final List<Community> communities;
  final List<DmThread> dms;

  /// null means the DM stand (Discord-like home), otherwise a community id.
  final String? activeCommunityId;
  final Scope? scope;
  final List<Message> messages;
  final List<Member> members;
  final Set<String> typing;
  final Map<String, int> unread;
  final bool loading;
  final String? error;

  HomeData copyWith({
    List<Community>? communities,
    List<DmThread>? dms,
    String? Function()? activeCommunityId,
    Scope? scope,
    List<Message>? messages,
    List<Member>? members,
    Set<String>? typing,
    Map<String, int>? unread,
    bool? loading,
    String? error,
  }) =>
      HomeData(
        communities: communities ?? this.communities,
        dms: dms ?? this.dms,
        activeCommunityId: activeCommunityId == null
            ? this.activeCommunityId
            : activeCommunityId(),
        scope: scope ?? this.scope,
        messages: messages ?? this.messages,
        members: members ?? this.members,
        typing: typing ?? this.typing,
        unread: unread ?? this.unread,
        loading: loading ?? this.loading,
        error: error,
      );
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) throw StateError('no session');
  return ChatRepository(ref.watch(connectionProvider), s);
});

final fileApiProvider = Provider<FileApi>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) throw StateError('no session');
  return FileApi(ref.watch(connectionProvider), s);
});

class FileCache extends Notifier<Map<String, Uint8List>> {
  @override
  Map<String, Uint8List> build() => {};

  Future<Uint8List> fetch(String fileId) async {
    final hit = state[fileId];
    if (hit != null) return hit;
    final bytes = await ref.read(fileApiProvider).download(fileId);
    state = {...state, fileId: bytes};
    return bytes;
  }
}

final fileCacheProvider =
    NotifierProvider<FileCache, Map<String, Uint8List>>(FileCache.new);

class HomeState extends Notifier<HomeData> {
  StreamSubscription<Map<String, dynamic>>? _pushSub;

  @override
  HomeData build() => const HomeData();

  Future<void> init() async {
    final repo = ref.read(chatRepositoryProvider);
    try {
      final comms = await repo.myCommunities();
      final dms = await repo.dmList();
      state = state.copyWith(communities: comms, dms: dms, loading: false);
      _pushSub ??= ref.read(connectionProvider).pushes.listen(_onPush);
      if (comms.isNotEmpty && comms.first.channels.isNotEmpty) {
        await selectChannel(comms.first, comms.first.channels.first);
      } else if (dms.isNotEmpty) {
        await selectDm(dms.first);
      }
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> refresh() async {
    final repo = ref.read(chatRepositoryProvider);
    final comms = await repo.myCommunities();
    final dms = await repo.dmList();
    state = state.copyWith(communities: comms, dms: dms);
  }

  Future<void> selectChannel(Community community, Channel channel) async {
    if (channel.type != 'text') return;
    state = state.copyWith(
        activeCommunityId: () => community.id,
        scope: ChannelScope(community, channel),
        messages: const [],
        members: const [],
        typing: {},
        loading: true,
        unread: {...state.unread}..remove('c:${channel.id}'));
    final repo = ref.read(chatRepositoryProvider);
    try {
      final msgs = await repo.historyChannel(channel.id);
      final members = await repo.members(community.id);
      if (state.scope?.key == 'c:${channel.id}') {
        state =
            state.copyWith(messages: msgs, members: members, loading: false);
      }
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> selectDm(DmThread thread) async {
    final myId = ref.read(sessionProvider)?.userId ?? '';
    state = state.copyWith(
        activeCommunityId: () => null,
        scope: DmScope(thread, myId),
        messages: const [],
        members: thread.members
            .map((m) => Member(userId: m.userId, nick: m.nick, role: ''))
            .toList(),
        typing: {},
        loading: true,
        unread: {...state.unread}..remove('d:${thread.id}'));
    try {
      final msgs = await ref.read(chatRepositoryProvider).historyDm(thread.id);
      if (state.scope?.key == 'd:${thread.id}') {
        state = state.copyWith(messages: msgs, loading: false);
      }
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// The DM stand: DMs only, no channels. Keeps the selected DM if any.
  void goHome() {
    final dm = state.scope is DmScope ? state.scope : null;
    state = HomeData(
      communities: state.communities,
      dms: state.dms,
      activeCommunityId: null,
      scope: dm,
      messages: dm == null ? const [] : state.messages,
      members: dm == null ? const [] : state.members,
      typing: {},
      unread: state.unread,
      loading: false,
    );
  }

  Future<void> send(String text) async {
    final scope = state.scope;
    final t = text.trim();
    if (scope == null || t.isEmpty) return;
    final repo = ref.read(chatRepositoryProvider);
    if (scope is ChannelScope) {
      await repo.sendChannel(scope.channel.id, t);
    } else if (scope is DmScope) {
      await repo.sendDm(scope.thread.id, t);
    }
  }

  void sendTyping(bool typing) {
    final scope = state.scope;
    final repo = ref.read(chatRepositoryProvider);
    if (scope is ChannelScope) {
      repo.sendTypingChannel(scope.channel.id, typing);
    } else if (scope is DmScope) {
      repo.sendTypingDm(scope.thread.id, typing);
    }
  }

  void _onPush(Map<String, dynamic> ev) {
    final type = ev['type']?.toString();
    final scope = state.scope;
    switch (type) {
      case 'message_new':
        final msg = Message.fromJson(ev);
        final key =
            msg.channelId != null ? 'c:${msg.channelId}' : 'd:${msg.dmId}';
        if (scope?.key == key) {
          state = state.copyWith(messages: [...state.messages, msg]);
        } else {
          state = state.copyWith(unread: {...state.unread}
            ..update(key, (v) => v + 1, ifAbsent: () => 1));
        }
        if (msg.dmId != null) _refreshDms();
      case 'message_edited':
        state = state.copyWith(
            messages: state.messages
                .map((m) => m.id == ev['message_id']
                    ? Message(
                        id: m.id,
                        channelId: m.channelId,
                        dmId: m.dmId,
                        authorId: m.authorId,
                        authorNick: m.authorNick,
                        text: (ev['text'] ?? m.text) as String,
                        createdAt: m.createdAt,
                        editedAt: ev['edited_at']?.toString(),
                        attachments: m.attachments)
                    : m)
                .toList());
      case 'message_deleted':
        state = state.copyWith(messages:
            state.messages.where((m) => m.id != ev['message_id']).toList());
      case 'typing':
        final scopeKey = ev['channel_id'] != null
            ? 'c:${ev['channel_id']}'
            : 'd:${ev['dm_id']}';
        final nick = (ev['nick'] ?? '?').toString();
        if (scope?.key == scopeKey &&
            (ev['is_typing'] as bool? ?? false)) {
          state = state.copyWith(typing: {...state.typing, nick});
          Future.delayed(const Duration(seconds: 4), () {
            state = state.copyWith(
                typing: state.typing.where((n) => n != nick).toSet());
          });
        } else if (!(ev['is_typing'] as bool? ?? false)) {
          state = state.copyWith(
              typing: state.typing.where((n) => n != nick).toSet());
        }
      case 'role_changed':
      case 'member_removed':
      case 'member_banned':
      case 'member_unbanned':
      case 'member_muted':
      case 'member_unmuted':
      case 'voice_joined':
      case 'voice_left':
        _refreshMembers();
    }
  }

  Future<void> _refreshDms() async {
    try {
      final dms = await ref.read(chatRepositoryProvider).dmList();
      state = state.copyWith(dms: dms);
    } catch (_) {}
  }

  Future<void> _refreshMembers() async {
    final scope = state.scope;
    if (scope is ChannelScope) {
      try {
        final members =
            await ref.read(chatRepositoryProvider).members(scope.community.id);
        if (state.scope?.key == scope.key) {
          state = state.copyWith(members: members);
        }
      } catch (_) {}
    }
  }
}

final homeStateProvider =
    NotifierProvider<HomeState, HomeData>(HomeState.new);
