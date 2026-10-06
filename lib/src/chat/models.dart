import '../auth/auth_repository.dart';

class Attachment {
  Attachment(
      {required this.fileId,
      required this.filename,
      required this.sizeBytes,
      required this.mime});
  final String fileId;
  final String filename;
  final int sizeBytes;
  final String mime;

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        fileId: j['file_id'] as String,
        filename: (j['filename'] ?? 'file') as String,
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        mime: (j['mime'] ?? '') as String,
      );
}

class CallInfo {
  CallInfo(
      {required this.status,
      this.durationSec = 0,
      this.video = false,
      this.endedBy});
  final String status; // completed|declined|missed|cancelled|offline
  final int durationSec;
  final bool video;
  final String? endedBy;

  factory CallInfo.fromJson(Map<String, dynamic> j) => CallInfo(
        status: (j['status'] ?? 'missed') as String,
        durationSec: (j['duration_sec'] as num?)?.toInt() ?? 0,
        video: (j['video'] ?? false) as bool,
        endedBy: j['ended_by'] as String?,
      );
}

class MissedCall {
  MissedCall(
      {required this.messageId,
      required this.dmId,
      required this.fromNick,
      required this.status,
      required this.video,
      required this.createdAt});
  final String messageId;
  final String dmId;
  final String fromNick;
  final String status;
  final bool video;
  final String createdAt;

  factory MissedCall.fromJson(Map<String, dynamic> j) => MissedCall(
        messageId: j['message_id'] as String,
        dmId: j['dm_id'] as String,
        fromNick: (j['from_nick'] ?? '?') as String,
        status: (j['status'] ?? 'missed') as String,
        video: (j['video'] ?? false) as bool,
        createdAt: (j['created_at'] ?? '') as String,
      );
}

class Message {
  Message(
      {required this.id,
      this.channelId,
      this.dmId,
      required this.authorId,
      required this.authorNick,
      required this.text,
      required this.createdAt,
      this.editedAt,
      this.attachments = const [],
      this.kind = 'text',
      this.call});
  final String id;
  final String? channelId;
  final String? dmId;
  final String authorId;
  final String authorNick;
  final String text;
  final String createdAt;
  final String? editedAt;
  final List<Attachment> attachments;
  final String kind;
  final CallInfo? call;

  bool get isCall => kind == 'call' && call != null;

  /// Broadcast feed entry (standalone channel post), not a chat message.
  bool get isPost => kind == 'post';

  factory Message.fromJson(Map<String, dynamic> j) {
    final callJson = j['call'];
    return Message(
      id: j['message_id'] as String,
      channelId: j['channel_id'] as String?,
      dmId: j['dm_id'] as String?,
      authorId: (j['author_id'] ?? '') as String,
      authorNick: (j['author_nick'] ?? '?') as String,
      text: (j['text'] ?? '') as String,
      createdAt: (j['created_at'] ?? '') as String,
      editedAt: j['edited_at'] as String?,
      attachments: ((j['attachments'] as List?) ?? const [])
          .map((a) => Attachment.fromJson(a as Map<String, dynamic>))
          .toList(),
      kind: (j['kind'] ?? 'text') as String,
      call: callJson is Map<String, dynamic>
          ? CallInfo.fromJson(callJson)
          : null,
    );
  }
}

class Channel {
  Channel({
    required this.id,
    required this.name,
    required this.type,
    this.alias = '',
    this.isPrivate = false,
    this.description = '',
    this.communityId,
    this.role = '',
    this.subscribersCount = -1,
  });
  final String id;
  final String name;
  final String type; // text | voice | broadcast
  /// Public address part: `channel/<alias>`. Empty when the server is old.
  final String alias;
  final bool isPrivate;
  final String description;
  /// Null = standalone channel (owns its access, not bound to a community).
  final String? communityId;
  /// My role in a standalone channel (owner/admin/member), '' if unknown.
  final String role;
  /// Known subscriber count (from my_channels), -1 if unknown.
  final int subscribersCount;

  /// Standalone channels are broadcast feeds (posts), not chatrooms.
  bool get isBroadcast => communityId == null;

  /// I may publish posts (owner/admin of a broadcast channel).
  bool get canPublish => role == 'owner' || role == 'admin';

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        id: j['channel_id'] as String,
        name: (j['name'] ?? '') as String,
        type: (j['channel_type'] ?? j['type'] ?? 'text') as String,
        alias: (j['alias'] ?? '') as String,
        isPrivate: (j['is_private'] ?? false) as bool,
        description: (j['description'] ?? '') as String,
        communityId: j['community_id'] as String?,
        role: (j['role'] ?? '') as String,
        subscribersCount:
            (j['subscribers_count'] as num?)?.toInt() ?? -1,
      );
}

class Community {
  Community({
    required this.id,
    required this.name,
    required this.role,
    required this.channels,
    this.alias = '',
    this.isPrivate = false,
  });
  final String id;
  final String name;
  final String role;
  final List<Channel> channels;
  /// Public address part: `server/<alias>`. Empty when the server is old.
  final String alias;
  final bool isPrivate;

  factory Community.fromJson(Map<String, dynamic> j) {
    final id = j['community_id'] as String;
    return Community(
      id: id,
      name: (j['name'] ?? '') as String,
      role: (j['role'] ?? 'member') as String,
      channels: ((j['channels'] as List?) ?? const [])
          .map((c) {
            final ch = Channel.fromJson(c as Map<String, dynamic>);
            // Channels arriving inside a community inherit its id, so the
            // client can tell bound from standalone ones.
            return ch.communityId == null
                ? Channel(
                    id: ch.id,
                    name: ch.name,
                    type: ch.type,
                    alias: ch.alias,
                    isPrivate: ch.isPrivate,
                    description: ch.description,
                    communityId: id,
                    role: ch.role,
                    subscribersCount: ch.subscribersCount)
                : ch;
          })
          .toList(),
      alias: (j['alias'] ?? '') as String,
      isPrivate: (j['is_private'] ?? false) as bool,
    );
  }
}

class DmMember {
  DmMember({required this.userId, required this.nick});
  final String userId;
  final String nick;
}

class DmThread {
  DmThread(
      {required this.id,
      required this.isGroup,
      required this.members,
      this.lastText});
  final String id;
  final bool isGroup;
  final List<DmMember> members;
  final String? lastText;

  String title(String myId) {
    final others = members.where((m) => m.userId != myId).toList();
    if (others.isEmpty) return 'Заметки';
    if (!isGroup && others.length == 1) return others.first.nick;
    return others.map((m) => m.nick).join(', ');
  }
}

class Member {
  Member({required this.userId, required this.nick, required this.role});
  final String userId;
  final String nick;
  final String role;
}

/// One entry of the side-panel attachments index (newest first).
class AttachmentIndexEntry {
  AttachmentIndexEntry({
    required this.attachmentId,
    required this.fileId,
    required this.filename,
    required this.mime,
    required this.sizeBytes,
    required this.messageId,
    required this.createdAt,
  });
  final String attachmentId;
  final String fileId;
  final String filename;
  final String mime;
  final int sizeBytes;
  final String messageId;
  final String createdAt;

  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');

  factory AttachmentIndexEntry.fromJson(Map<String, dynamic> j) =>
      AttachmentIndexEntry(
        attachmentId: j['attachment_id'] as String,
        fileId: (j['file_id'] ?? '') as String,
        filename: (j['filename'] ?? 'file') as String,
        mime: (j['mime'] ?? '') as String,
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        messageId: (j['message_id'] ?? '') as String,
        createdAt: (j['created_at'] ?? '') as String,
      );
}

class AttachmentsIndex {
  AttachmentsIndex({required this.items, required this.hasMore});
  final List<AttachmentIndexEntry> items;
  final bool hasMore;
}

/// Russian copy for upload failures. Never surfaces raw backend codes.
String friendlyUploadError(Object e) {
  if (e is GrchatException) {
    return switch (e.code) {
      'BAD_FILENAME' => 'Некорректное имя файла.',
      'FILE_TOO_BIG' => 'Файл слишком большой.',
      'BAD_MIME' => 'Этот тип файлов запрещён.',
      'QUOTA_EXCEEDED' => 'Квота исчерпана.',
      'TOO_MANY_UPLOADS' => 'Слишком много загрузок, подожди.',
      'NOT_MEMBER' => 'Нет доступа.',
      'BANNED' => 'Доступ запрещён.',
      'MUTED' => 'Нельзя писать в этот чат.',
      _ => 'Не удалось отправить сообщение. Проверьте соединение.',
    };
  }
  return 'Не удалось отправить сообщение. Проверьте соединение.';
}
