import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/group_call.dart';
import 'package:grchat_client/src/call/media_session.dart';
import 'package:grchat_client/src/voice/voice_state.dart';

/// One realtime session, enforced by [MediaCoordinator] (§1, §47–§52).
///
/// Fake transports: record engine verbs, never touch network/media. The
/// coordinator under test only calls the public engine surface
/// (endAll/leave/acceptIncoming) plus reads provider state.

class _FakeDirect extends CallState {
  _FakeDirect([this._c]);
  ActiveCall? _c;
  final calls = <String>[];
  bool hangForever = false;

  @override
  ActiveCall? build() => _c;

  void drop() {
    _c = null;
    state = null;
  }

  @override
  Future<void> hangup() async {
    calls.add('direct-hangup');
    _c = null;
    state = null;
  }

  @override
  Future<void> decline() async {
    calls.add('direct-decline');
    _c = null;
    state = null;
  }

  @override
  Future<void> acceptIncoming() async {
    calls.add('direct-accept');
    final c = _c;
    if (c != null) state = c.copyWith(phase: CallPhase.active);
  }

  @override
  Future<void> endAll({String? exceptPendingId}) async {
    final c = _c;
    if (c != null &&
        !c.outgoing &&
        c.phase == CallPhase.ringing &&
        c.callId == exceptPendingId) {
      calls.add('direct-endAll-keep');
      return;
    }
    if (c != null) calls.add('direct-endAll');
    if (hangForever) await Completer<void>().future;
    _c = null;
    state = null;
  }
}

class _FakeGroup extends GroupCallState {
  _FakeGroup([this._c]);
  GroupCall? _c;
  final calls = <String>[];

  @override
  GroupCall? build() => _c;

  @override
  Future<void> hangup() async {
    calls.add('group-hangup');
    _c = null;
    state = null;
  }

  @override
  Future<void> decline() async {
    calls.add('group-decline');
    _c = null;
    state = null;
  }

  @override
  Future<void> acceptIncoming() async {
    calls.add('group-accept');
    final c = _c;
    if (c != null) state = c.copyWith(phase: GroupPhase.active);
  }

  @override
  Future<void> endAll({String? exceptPendingId}) async {
    final c = _c;
    if (c != null &&
        !c.outgoing &&
        c.phase == GroupPhase.ringing &&
        c.callId == exceptPendingId) {
      calls.add('group-endAll-keep');
      return;
    }
    if (c != null) calls.add('group-endAll');
    _c = null;
    state = null;
  }
}

class _FakeVoice extends VoiceSessionState {
  _FakeVoice([this._s]);
  VoiceSession? _s;
  final calls = <String>[];

  /// When set, leave waits on it (double-accept test).
  Completer<void>? blockLeave;

  @override
  VoiceSession? build() => _s;

  @override
  Future<void> leave() async {
    calls.add('voice-leave');
    if (blockLeave != null) await blockLeave!.future;
    _s = null;
    state = null;
  }

  @override
  Future<void> join(
      {required String channelId, required String title}) async {
    calls.add('voice-join:$channelId');
    _s = VoiceSession(channelId: channelId, title: title, room: 'r');
    state = _s;
  }
}

ActiveCall _activeDirect(String id, String nick) => ActiveCall(
    callId: id,
    peerNick: nick,
    video: false,
    outgoing: true,
    phase: CallPhase.active);

ActiveCall _pendingDirect(String id, String nick) => ActiveCall(
    callId: id,
    peerNick: nick,
    video: true,
    outgoing: false,
    phase: CallPhase.ringing);

GroupCall _pendingGroup(String id) => GroupCall(
    dmId: 'd1',
    title: 'Team',
    room: 'grchat_d1',
    video: true,
    outgoing: false,
    phase: GroupPhase.ringing,
    callId: id);

GroupCall _activeGroup(String id) => GroupCall(
    dmId: 'd1',
    title: 'Team',
    room: 'grchat_d1',
    video: true,
    outgoing: true,
    phase: GroupPhase.active,
    callId: id);

VoiceSession _voice(String channel) =>
    VoiceSession(channelId: channel, title: 'Studio', room: 'r');

/// Live (media-holding) sessions right now. Dry pendings hold no mic/cam
/// and do not count (§52).
int _liveCount(ProviderContainer c) {
  var n = 0;
  final d = c.read(callStateProvider);
  if (d != null && (d.outgoing || d.phase == CallPhase.active)) n++;
  final g = c.read(groupCallProvider);
  if (g != null && (g.outgoing || g.phase == GroupPhase.active)) n++;
  if (c.read(voiceSessionProvider) != null) n++;
  return n;
}

ProviderContainer _container(
    {_FakeDirect? direct, _FakeGroup? group, _FakeVoice? voice}) {
  final c = ProviderContainer(overrides: [
    if (direct != null) callStateProvider.overrideWith(() => direct),
    if (group != null) groupCallProvider.overrideWith(() => group),
    if (voice != null) voiceSessionProvider.overrideWith(() => voice),
  ]);
  addTearDown(c.dispose);
  c.read(mediaCoordinatorProvider.notifier).endTimeout =
      const Duration(milliseconds: 100);
  return c;
}

MediaCoordinator _coord(ProviderContainer c) =>
    c.read(mediaCoordinatorProvider.notifier);

void main() {
  group('arbitration basics', () {
    test('idle slot is free, nothing active', () {
      final c = _container();
      expect(_coord(c).requestSlot('x'), SessionRequest.free);
      expect(_coord(c).activeMedia(), isNull);
      expect(_coord(c).hasPendingIncoming(), isFalse);
    });

    test('active P2P needs confirmation and a label', () {
      final c = _container(direct: _FakeDirect(_activeDirect('a', 'Alex')));
      expect(_coord(c).requestSlot('call'), SessionRequest.confirm);
      expect(_coord(c).describeCurrent(), 'звонок: Alex');
      expect(
          _coord(c).switchWarningFor(MediaSessionKind.group),
          'Вы разговариваете с Alex.');
    });

    test('outgoing direct counts as busy (§18)', () {
      final c = _container(
          direct: _FakeDirect(ActiveCall(
              callId: 'a',
              peerNick: 'Alex',
              video: false,
              outgoing: true,
              phase: CallPhase.ringing)));
      expect(_coord(c).requestSlot('call'), SessionRequest.confirm);
    });

    test('voice and group labels for warnings', () {
      final v = _container(voice: _FakeVoice(_voice('vc1')));
      expect(_coord(v).switchWarningFor(MediaSessionKind.direct),
          'Вы сейчас в голосовом канале «Studio».');
      final g = _container(group: _FakeGroup(_activeGroup('g1')));
      expect(_coord(g).switchWarningFor(MediaSessionKind.direct),
          'Вы участвуете в групповом звонке «Team».');
      expect(_coord(_container()).switchWarningFor(
          MediaSessionKind.direct), isNull);
    });
  });

  group('atomic accept (§3)', () {
    test('voice → P2P: leave first, then accept, one live', () async {
      final fd = _FakeDirect(_pendingDirect('b', 'Masha'));
      final fv = _FakeVoice(_voice('vc1'));
      final c = _container(direct: fd, voice: fv);
      final r = await _coord(c).acceptIncoming(
          kind: MediaSessionKind.direct, pendingId: 'b');
      expect(r, SwitchResult.switched);
      expect(fv.calls, ['voice-leave']);
      expect(fd.calls, ['direct-endAll-keep', 'direct-accept']);
      expect(_liveCount(c), 1);
      expect(c.read(callStateProvider)?.phase, CallPhase.active);
    });

    test('P2P active + group pending → accept group ends P2P', () async {
      final fd = _FakeDirect(_activeDirect('a', 'Alex'));
      final fg = _FakeGroup(_pendingGroup('g1'));
      final c = _container(direct: fd, group: fg);
      final r = await _coord(c).acceptIncoming(
          kind: MediaSessionKind.group, pendingId: 'g1');
      expect(r, SwitchResult.switched);
      expect(fd.calls, ['direct-endAll']);
      expect(fg.calls, ['group-endAll-keep', 'group-accept']);
      expect(_liveCount(c), 1);
    });

    test('switchStart declines a stray group pending (no HOLD)', () async {
      // A bare group pending that is NOT being accepted dies on switch.
      final fg = _FakeGroup(_pendingGroup('g1'));
      final fv = _FakeVoice(_voice('vc1'));
      final c = _container(group: fg, voice: fv);
      final r = await _coord(c)
          .switchStart(() async {}, 'noop while group pending');
      expect(r, SwitchResult.switched);
      expect(fg.calls, ['group-endAll']);
    });

    test('callee hung up mid-switch → abort, nothing live (§37)', () async {
      final fd = _FakeDirect(_pendingDirect('b', 'Masha'));
      final fv = _FakeVoice(_voice('vc1'));
      final c = _container(direct: fd, voice: fv);
      // Caller hung up before we accepted: the pending vanishes.
      c.read(callStateProvider);
      fd.drop();
      final r = await _coord(c).acceptIncoming(
          kind: MediaSessionKind.direct, pendingId: 'b');
      expect(r, SwitchResult.aborted);
      expect(_coord(c).activeMedia(), isNull);
      expect(
          c.read(callNoticeProvider), 'Звонок завершён вызывающим');
    });

    test('double accept: second is busy, one switch (§51)', () async {
      final fd = _FakeDirect(_pendingDirect('b', 'Masha'));
      final fv = _FakeVoice(_voice('vc1'))
        ..blockLeave = Completer<void>();
      final c = _container(direct: fd, voice: fv);
      final first = _coord(c).acceptIncoming(
          kind: MediaSessionKind.direct, pendingId: 'b');
      expect(_coord(c).requestSlot('second'), SessionRequest.busy);
      final second = await _coord(c).acceptIncoming(
          kind: MediaSessionKind.direct, pendingId: 'b');
      expect(second, SwitchResult.busy);
      fv.blockLeave!.complete();
      expect(await first, SwitchResult.switched);
      expect(_liveCount(c), 1);
    });

    test('stuck old end does not block the new one (§24)', () async {
      final fd = _FakeDirect(_activeDirect('a', 'Alex'))
        ..hangForever = true;
      final order = <String>[];
      final c = _container(direct: fd);
      final r = await _coord(c).switchStart(() async {
        order.add('start-new');
      }, 'voice Studio');
      expect(r, SwitchResult.switched);
      expect(order, ['start-new']);
    });
  });

  group('outgoing and joins', () {
    test('P2P → voice join: hangup first (§10)', () async {
      final fd = _FakeDirect(_activeDirect('a', 'Masha'));
      final fv = _FakeVoice();
      final c = _container(direct: fd, voice: fv);
      expect(_coord(c).requestSlot('voice'), SessionRequest.confirm);
      final r = await _coord(c).switchStart(
          () => fv.join(channelId: 'vc1', title: 'Studio'),
          'voice Studio');
      expect(r, SwitchResult.switched);
      expect(fd.calls, ['direct-endAll']);
      expect(fv.calls, ['voice-leave', 'voice-join:vc1']);
      expect(_liveCount(c), 1);
    });

    test('voice → voice: leave, then join (§11)', () async {
      final fv = _FakeVoice(_voice('vcA'));
      final c = _container(voice: fv);
      final r = await _coord(c).switchStart(
          () => fv.join(channelId: 'vcB', title: 'Studio'),
          'voice Studio');
      expect(r, SwitchResult.switched);
      expect(fv.calls, ['voice-leave', 'voice-join:vcB']);
      expect(_liveCount(c), 1);
    });

    test('group → P2P outgoing: group hangs up (§12)', () async {
      final fg = _FakeGroup(_activeGroup('g1'));
      final fd = _FakeDirect();
      final c = _container(group: fg, direct: fd);
      final r = await _coord(c).switchStart(() async {}, 'direct out');
      expect(r, SwitchResult.switched);
      expect(fg.calls, ['group-endAll']);
      expect(_liveCount(c), 0);
    });

    test('failed start never resurrects the old session (§35)', () async {
      final fv = _FakeVoice(_voice('vcA'));
      final c = _container(voice: fv);
      var failed = false;
      try {
        await _coord(c).switchStart(() async {
          throw Exception('sfu down');
        }, 'voice Studio');
      } catch (_) {
        failed = true;
      }
      expect(failed, isTrue);
      expect(fv.calls, ['voice-leave']);
      expect(_liveCount(c), 0);
    });
  });

  group('incoming door policy (§15, §16)', () {
    test('second pending is declined at the door', () {
      // Direct dry ring pending + group invite: the group engine must
      // decline quietly instead of showing a second accept.
      final fd = _FakeDirect(_pendingDirect('b', 'Masha'));
      final c = _container(direct: fd);
      expect(_coord(c).hasPendingIncoming(), isTrue);
      c.read(groupCallProvider.notifier).incoming(
          callId: 'g1',
          dmId: 'd1',
          room: 'grchat_d1',
          video: true,
          fromNick: 'Second');
      expect(c.read(groupCallProvider), isNull);
    });

    test('waiting is allowed over a live voice session (§45)', () {
      final fv = _FakeVoice(_voice('vc1'));
      final c = _container(voice: fv);
      expect(_coord(c).hasPendingIncoming(), isFalse);
      c.read(groupCallProvider.notifier).incoming(
          callId: 'g1',
          dmId: 'd1',
          room: 'grchat_d1',
          video: true,
          fromNick: 'Second');
      final g = c.read(groupCallProvider);
      expect(g?.phase, GroupPhase.ringing);
      expect(_liveCount(c), 1);
    });
  });
}
