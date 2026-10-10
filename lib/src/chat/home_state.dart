import 'dart:async';
import 'dart:typed_data';

import 'package:riverpod/riverpod.dart';

import '../app/providers.dart';
import '../call/call_session.dart';
import '../desktop/window.dart';
import '../notify/notify.dart';
import '../voice/voice_state.dart';
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

  /// Null = standalone channel (not bound to any community).
  final Community? community;
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
    this.myChannels = const [],
    this.dms = const [],
    this.activeCommunityId,
    this.scope,
    this.messages = const [],
    this.members = const [],
    this.typing = const {},
    this.unread = const {},
    this.missed = const [],
    this.loading = true,
    this.loadingOlder = false,
    this.hasMore = true,
    this.error,
  });

  final List<Community> communities;

  /// Standalone channels I subscribed to (community channels ride along
  /// their community).
  final List<Channel> myChannels;
  final List<DmThread> dms;

  /// null means the DM stand (Discord-like home), otherwise a community id.
  final String? activeCommunityId;
  final Scope? scope;
  final List<Message> messages;
  final List<Member> members;
  final Set<String> typing;
  final Map<String, int> unread;
  /// Missed calls accumulated while offline (server clears flags on read).
  final List<MissedCall> missed;
  final bool loading;
  final bool loadingOlder;
  final bool hasMore;
  final String? error;

  HomeData copyWith({
    List<Community>? communities,
    List<Channel>? myChannels,
    List<DmThread>? dms,
    String? Function()? activeCommunityId,
    Scope? scope,
    List<Message>? messages,
    List<Member>? members,
    Set<String>? typing,
    Map<String, int>? unread,
    List<MissedCall>? missed,
    bool? loading,
    bool? loadingOlder,
    bool? hasMore,
    String? error,
  }) =>
      HomeData(
        communities: communities ?? this.communities,
        myChannels: myChannels ?? this.myChannels,
        dms: dms ?? this.dms,
        activeCommunityId: activeCommunityId == null
            ? this.activeCommunityId
            : activeCommunityId(),
        scope: scope ?? this.scope,
        messages: messages ?? this.messages,
        members: members ?? this.members,
        typing: typing ?? this.typing,
        unread: unread ?? this.unread,
        missed: missed ?? this.missed,
        loading: loading ?? this.loading,
        loadingOlder: loadingOlder ?? this.loadingOlder,
        hasMore: hasMore ?? this.hasMore,
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

  /// Last text/dm scope the user actually read. Voice leave returns here
  /// (§24); voice scope itself is never recorded.
  Scope? lastTextScope;

  @override
  HomeData build() => const HomeData();

  Future<void> init() async {
    final repo = ref.read(chatRepositoryProvider);
    try {
      final comms = await repo.myCommunities();
      if (!ref.mounted) return;
      // Tolerated: old servers have no list_my_channels yet.
      List<Channel> chans = const [];
      try {
        chans = await repo.myChannels();
      } catch (_) {}
      if (!ref.mounted) return;
      final dms = await repo.dmList();
      if (!ref.mounted) return;
      state = state.copyWith(
          communities: comms, myChannels: chans, dms: dms, loading: false);
      _pushSub ??= ref.read(connectionProvider).pushes.listen(_onPush);
      if (comms.isNotEmpty && comms.first.channels.isNotEmpty) {
        await selectChannel(comms.first, comms.first.channels.first);
      } else if (dms.isNotEmpty) {
        await selectDm(dms.first);
      }
      if (!ref.mounted) return;
      await checkMissed();
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: e.toString());
      }
    }
  }

  /// Calls missed while offline. Server flags are one-shot: each record
  /// is reported once, so repeats are safe.
  Future<void> checkMissed() async {
    try {
      final missed = await ref.read(chatRepositoryProvider).missedCalls();
      if (missed.isNotEmpty) {
        state = state.copyWith(missed: [...state.missed, ...missed]);
      }
    } catch (_) {}
  }

  void clearMissed() {
    if (state.missed.isNotEmpty) state = state.copyWith(missed: []);
  }

  /// Open the DM of the first missed call (banner action).
  Future<void> openMissed() async {
    final missed = state.missed;
    if (missed.isEmpty) return;
    final dmId = missed.first.dmId;
    final threads = state.dms.where((d) => d.id == dmId);
    state = state.copyWith(missed: []);
    if (threads.isNotEmpty) await selectDm(threads.first);
  }

  /// System notification unless the user is already looking at it.
  /// Call records never toast: they arrive after the fact (the ringing
  /// toast, banner and chat card already cover the call), so notifying
  /// them looks like stale spam. Same for belated pushes.
  void _maybeNotify(Message msg, String key) {
    if (msg.isCall) return;
    final created =
        DateTime.tryParse(msg.createdAt)?.toLocal() ?? DateTime.now();
    if (DateTime.now().difference(created) > const Duration(minutes: 3)) {
      return;
    }
    () async {
      try {
        if (await windowEngaged() && state.scope?.key == key) return;
        final backend = ref.read(notifyBackendProvider);
        if (!backend.supported) return;
        final title = msg.dmId != null
            ? msg.authorNick
            : '${_channelName(msg.channelId)} · ${msg.authorNick}';
        var body = msg.text.trim();
        if (body.isEmpty) {
          body = msg.attachments.isEmpty ? 'Новое сообщение' : 'Вложение';
        }
        if (body.length > 120) body = '${body.substring(0, 120)}…';
        backend.showMessage(
          tag: 'chat:$key',
          title: title,
          body: body,
          onTap: () async {
            await focusWindow();
            openByKey(key);
          },
        );
      } catch (_) {}
    }();
  }

  String _channelName(String? channelId) {
    if (channelId == null) return 'Чат';
    String? name;
    var broadcast = false;
    for (final comm in state.communities) {
      for (final ch in comm.channels) {
        if (ch.id == channelId) {
          name = ch.name;
          broadcast = ch.isBroadcast;
        }
      }
    }
    for (final ch in state.myChannels) {
      if (ch.id == channelId) {
        name = ch.name;
        broadcast = true;
      }
    }
    if (name == null) return 'Чат';
    return broadcast ? name : '#$name';
  }

  /// Jump to a conversation by scope key (notification tap).
  Future<void> openByKey(String key) async {
    if (key.startsWith('d:')) {
      final id = key.substring(2);
      final threads = state.dms.where((d) => d.id == id);
      if (threads.isNotEmpty) await selectDm(threads.first);
    } else if (key.startsWith('c:')) {
      final id = key.substring(2);
      for (final comm in state.communities) {
        final chs = comm.channels.where((c) => c.id == id);
        if (chs.isNotEmpty) {
          await selectChannel(comm, chs.first);
          return;
        }
      }
      final mine = state.myChannels.where((c) => c.id == id);
      if (mine.isNotEmpty) await selectStandaloneChannel(mine.first);
    }
  }

  Future<void> refresh() async {
    final repo = ref.read(chatRepositoryProvider);
    final comms = await repo.myCommunities();
    // Tolerated: old servers have no list_my_channels yet.
    List<Channel> chans = state.myChannels;
    try {
      chans = await repo.myChannels();
    } catch (_) {}
    final dms = await repo.dmList();
    state = state.copyWith(communities: comms, myChannels: chans, dms: dms);
  }

  /// Called after the transport reconnects: re-auth if needed, then
  /// reload lists and the current conversation. Returns false when
  /// the session is dead with no saved credentials (caller logs out).
  Future<bool> resync() async {
    final auth = ref.read(authRepositoryProvider);
    if (!await auth.ensureSession()) {
      final s = auth.session;
      if (s == null) return false;
    }
    final s = ref.read(authRepositoryProvider).session;
    if (s != null) ref.read(sessionProvider.notifier).set(s);
    try {
      await refresh();
    } catch (_) {
      return true; // lists failed, scope reload below may still work
    }
    final scope = state.scope;
    try {
      if (scope is ChannelScope) {
        if (scope.community == null) {
          final mine =
              state.myChannels.where((c) => c.id == scope.channel.id);
          if (mine.isEmpty) return true;
          await selectStandaloneChannel(mine.first);
        } else {
          final comms = state.communities
              .where((c) => c.id == scope.community!.id);
          if (comms.isEmpty) return true;
          final chs = comms.first.channels
              .where((c) => c.id == scope.channel.id);
          if (chs.isEmpty) return true;
          await selectChannel(comms.first, chs.first);
        }
      } else if (scope is DmScope) {
        final threads =
            state.dms.where((d) => d.id == scope.thread.id);
        if (threads.isEmpty) return true;
        await selectDm(threads.first);
      }
    } catch (_) {}
    await checkMissed();
    return true;
  }

  Future<void> selectChannel(Community? community, Channel channel) async {
    if (channel.type != 'text' && channel.type != 'broadcast') return;
    lastTextScope = ChannelScope(community, channel);
    // Reading text while in a call folds the window, never stops media (§33).
    minimizeLiveCall(ref);
    ref.read(editingMessageProvider.notifier).clear();
    state = state.copyWith(
        activeCommunityId: () => community?.id,
        scope: ChannelScope(community, channel),
        messages: const [],
        members: const [],
        typing: {},
        loading: true,
        loadingOlder: false,
        hasMore: true,
        unread: {...state.unread}..remove('c:${channel.id}'));
    final repo = ref.read(chatRepositoryProvider);
    try {
      final msgs = await repo.historyChannel(channel.id);
      // Standalone channels have no community roster.
      final members =
          community == null ? const <Member>[] : await repo.members(community.id);
      if (state.scope?.key == 'c:${channel.id}') {
        state =
            state.copyWith(messages: msgs, members: members, loading: false);
      }
      if (community != null) {
        final voice = ref.read(voiceStateProvider.notifier);
        final session = ref.read(voiceSessionProvider.notifier);
        for (final ch in community.channels) {
          if (ch.type != 'text') voice.refresh(ch.id).catchError((_) {});
          // Voice caps for the roster header (nicks/mutes/limit, no join).
          if (ch.type == 'voice') {
            session.refreshChannel(ch.id).catchError((_) {});
          }
        }
      }
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Opens a standalone channel found via search (no community context).
  Future<void> selectStandaloneChannel(Channel channel) =>
      selectChannel(null, channel);

  /// Focus a voice channel scope: no history load, no composer. If our live
  /// voice session is in this channel, expand the window (§17, no rejoin);
  /// otherwise the scope just selects and the tile offers joining.
  void selectVoiceScope(Community? community, Channel channel) {
    if (channel.type != 'voice') return;
    state = state.copyWith(
        activeCommunityId: () => community?.id,
        scope: ChannelScope(community, channel),
        messages: const [],
        members: const [],
        typing: {},
        loading: false,
        unread: {...state.unread}..remove('c:${channel.id}'));
    final session = ref.read(voiceSessionProvider);
    if (session != null && session.channelId == channel.id) {
      ref.read(voiceSessionProvider.notifier).setMinimized(false);
    }
  }

  /// After leaving a voice channel, go back to the last viewed text/dm
  /// scope when it still exists (§24). Stays put otherwise.
  Future<void> reselectLastText() async {
    final last = lastTextScope;
    if (last is DmScope) {
      final threads = state.dms.where((d) => d.id == last.thread.id);
      if (threads.isNotEmpty) {
        await selectDm(threads.first);
      }
    } else if (last is ChannelScope) {
      final lc = last.channel;
      if (lc.type != 'text' && lc.type != 'broadcast') return;
      if (last.community == null) {
        final mine = state.myChannels.where((c) => c.id == lc.id);
        if (mine.isNotEmpty) await selectStandaloneChannel(mine.first);
      } else {
        final comms =
            state.communities.where((c) => c.id == last.community!.id);
        if (comms.isEmpty) return;
        final chs = comms.first.channels.where((c) => c.id == lc.id);
        if (chs.isNotEmpty) await selectChannel(comms.first, chs.first);
      }
    }
  }

  Future<void> selectDm(DmThread thread) async {
    lastTextScope = DmScope(thread, ref.read(sessionProvider)?.userId ?? '');
    minimizeLiveCall(ref);
    ref.read(editingMessageProvider.notifier).clear();
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
        loadingOlder: false,
        hasMore: true,
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
    minimizeLiveCall(ref);
    ref.read(editingMessageProvider.notifier).clear();
    final dm = state.scope is DmScope ? state.scope : null;
    state = HomeData(
      communities: state.communities,
      myChannels: state.myChannels,
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

  /// Loads an older page above the current first message.
  /// Returns how many messages were prepended.
  Future<int> loadOlder() async {
    final scope = state.scope;
    if (scope == null ||
        state.loadingOlder ||
        !state.hasMore ||
        state.messages.isEmpty) {
      return 0;
    }
    state = state.copyWith(loadingOlder: true);
    try {
      final repo = ref.read(chatRepositoryProvider);
      final beforeId = state.messages.first.id;
      late final List<Message> older;
      if (scope is ChannelScope) {
        older = await repo.historyChannel(scope.channel.id,
            beforeId: beforeId);
      } else if (scope is DmScope) {
        older =
            await repo.historyDm(scope.thread.id, beforeId: beforeId);
      } else {
        state = state.copyWith(loadingOlder: false);
        return 0;
      }
      final known = state.messages.map((m) => m.id).toSet();
      final fresh = older.where((m) => !known.contains(m.id)).toList();
      state = state.copyWith(
        messages: [...fresh, ...state.messages],
        loadingOlder: false,
        hasMore: older.length >= 50,
      );
      return fresh.length;
    } catch (_) {
      state = state.copyWith(loadingOlder: false);
      return 0;
    }
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

  Future<void> editMessage(String messageId, String text) async {
    await ref
        .read(chatRepositoryProvider)
        .editMessage(messageId, text);
  }

  Future<void> deleteMessage(String messageId) async {
    await ref
        .read(chatRepositoryProvider)
        .deleteMessage(messageId);
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
        if (msg.dmId != null) refreshDms();
        _maybeNotify(msg, key);
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
                        attachments: m.attachments,
                        kind: m.kind,
                        call: m.call)
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

  /// Reloads the DM list (new/changed threads). Public for call
  /// escalation, which creates a group DM mid-call.
  Future<void> refreshDms() async {
    try {
      final dms = await ref.read(chatRepositoryProvider).dmList();
      state = state.copyWith(dms: dms);
    } catch (_) {}
  }

  Future<void> _refreshMembers() async {
    final scope = state.scope;
    if (scope is ChannelScope && scope.community != null) {
      try {
        final members = await ref
            .read(chatRepositoryProvider)
            .members(scope.community!.id);
        if (state.scope?.key == scope.key) {
          state = state.copyWith(members: members);
        }
      } catch (_) {}
    }
  }
}

final homeStateProvider =
    NotifierProvider<HomeState, HomeData>(HomeState.new);

/// Message being edited inline in the composer (Telegram-style banner).
/// Null = plain compose mode. Cleared on scope switch.
class EditingMessage extends Notifier<Message?> {
  @override
  Message? build() => null;

  void begin(Message m) => state = m;
  void clear() => state = null;
}

final editingMessageProvider =
    NotifierProvider<EditingMessage, Message?>(EditingMessage.new);
