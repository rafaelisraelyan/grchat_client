import '../auth/auth_repository.dart';
import '../transport/grchat_connection.dart';
import 'models.dart';

/// Server API: communities, DMs, messages, members. Token from [Session].
class ChatRepository {
  ChatRepository(this._conn, this._session);
  final GrchatConnection _conn;
  final Session _session;

  Map<String, String> get _auth => {'session_token': _session.token};

  Future<List<Community>> myCommunities() async {
    final r = await _conn.request('list_my_communities', fields: _auth);
    _throwIfError(r);
    return ((r['communities'] as List?) ?? const [])
        .map((c) => Community.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<List<DmThread>> dmList() async {
    final r = await _conn.request('dm_list', fields: _auth);
    _throwIfError(r);
    return ((r['dms'] as List?) ?? const []).map((d) {
      final j = d as Map<String, dynamic>;
      return DmThread(
        id: j['dm_id'] as String,
        isGroup: (j['is_group'] ?? false) as bool,
        members: ((j['members'] as List?) ?? const [])
            .map((m) => DmMember(
                userId: _str(m, 'user_id'), nick: _str(m, 'nick')))
            .toList(),
        lastText: (j['last_message'] as Map?)?['text'],
      );
    }).toList();
  }

  Future<List<Message>> historyChannel(String channelId, {int limit = 50}) async {
    final r = await _conn.request('history',
        fields: {..._auth, 'channel_id': channelId, 'limit': limit});
    _throwIfError(r);
    return ((r['messages'] as List?) ?? const [])
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  Future<List<Message>> historyDm(String dmId, {int limit = 50}) async {
    final r = await _conn.request('history',
        fields: {..._auth, 'dm_id': dmId, 'limit': limit});
    _throwIfError(r);
    return ((r['messages'] as List?) ?? const [])
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  Future<void> sendChannel(String channelId, String text) async {
    _throwIfError(await _conn.request('message_send',
        fields: {..._auth, 'channel_id': channelId, 'text': text}));
  }

  Future<void> sendDm(String dmId, String text) async {
    _throwIfError(await _conn.request('message_send',
        fields: {..._auth, 'dm_id': dmId, 'text': text}));
  }

  Future<void> sendTypingChannel(String channelId, bool typing) async {
    try {
      await _conn.request('typing',
          fields: {..._auth, 'channel_id': channelId, 'is_typing': typing});
    } catch (_) {}
  }

  Future<void> sendTypingDm(String dmId, bool typing) async {
    try {
      await _conn.request('typing',
          fields: {..._auth, 'dm_id': dmId, 'is_typing': typing});
    } catch (_) {}
  }

  Future<List<Member>> members(String communityId) async {
    final r = await _conn.request('community_members',
        fields: {..._auth, 'community_id': communityId});
    _throwIfError(r);
    return ((r['members'] as List?) ?? const [])
        .map((m) => Member(
            userId: _str(m, 'user_id'),
            nick: _str(m, 'nick'),
            role: _str(m, 'role')))
        .toList();
  }

  Future<String> openDm(String nick) async {
    final r = await _conn.request('dm_open', fields: {..._auth, 'nick': nick});
    _throwIfError(r);
    return r['dm_id'] as String;
  }

  Future<({String userId, String nick})> findUser(String nick) async {
    final r = await _conn.request('find_user', fields: {..._auth, 'nick': nick});
    _throwIfError(r);
    return (userId: r['user_id'] as String, nick: r['nick'] as String);
  }

  Future<String> createCommunity(String name) async {
    final r =
        await _conn.request('create_community', fields: {..._auth, 'name': name});
    _throwIfError(r);
    return r['community_id'] as String;
  }

  Future<String> createInvite(String communityId) async {
    final r = await _conn.request('create_invite',
        fields: {..._auth, 'community_id': communityId});
    _throwIfError(r);
    return r['code'] as String;
  }

  Future<void> joinByInvite(String code) async {
    _throwIfError(await _conn.request('join_by_invite',
        fields: {..._auth, 'code': code.trim()}));
  }

  void _throwIfError(Map<String, dynamic> r) {
    if (r['type'] == 'error') {
      throw GrchatException(r['code']?.toString() ?? 'UNKNOWN', r);
    }
  }

  static String _str(dynamic m, String key) =>
      ((m as Map?)?[key] ?? '').toString();
}
