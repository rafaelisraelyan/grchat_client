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
      this.attachments = const []});
  final String id;
  final String? channelId;
  final String? dmId;
  final String authorId;
  final String authorNick;
  final String text;
  final String createdAt;
  final String? editedAt;
  final List<Attachment> attachments;

  factory Message.fromJson(Map<String, dynamic> j) => Message(
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
      );
}

class Channel {
  Channel({required this.id, required this.name, required this.type});
  final String id;
  final String name;
  final String type; // text | voice

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        id: j['channel_id'] as String,
        name: j['name'] as String,
        type: (j['channel_type'] ?? j['type'] ?? 'text') as String,
      );
}

class Community {
  Community(
      {required this.id,
      required this.name,
      required this.role,
      required this.channels});
  final String id;
  final String name;
  final String role;
  final List<Channel> channels;

  factory Community.fromJson(Map<String, dynamic> j) => Community(
        id: j['community_id'] as String,
        name: j['name'] as String,
        role: (j['role'] ?? 'member') as String,
        channels: ((j['channels'] as List?) ?? const [])
            .map((c) => Channel.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
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
