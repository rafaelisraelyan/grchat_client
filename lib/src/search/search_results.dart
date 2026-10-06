import '../auth/auth_repository.dart';
import '../chat/models.dart';
import 'search_address.dart';

/// A server resolved by `server/<alias>`. Discovery, not access:
/// a private server is shown as private, joining needs an invite.
class ServerHit {
  ServerHit({
    required this.communityId,
    required this.name,
    required this.alias,
    required this.isPrivate,
    required this.membersCount,
    required this.isMember,
  });
  final String communityId;
  final String name;
  final String alias;
  final bool isPrivate;
  final int membersCount;
  final bool isMember;

  String get address => addressOf(SearchTargetType.server, alias);

  factory ServerHit.fromJson(Map<String, dynamic> j) => ServerHit(
        communityId: j['community_id'] as String,
        name: (j['name'] ?? '') as String,
        alias: (j['alias'] ?? '') as String,
        isPrivate: (j['is_private'] ?? false) as bool,
        membersCount: (j['members_count'] as num?)?.toInt() ?? 0,
        isMember: (j['is_member'] ?? false) as bool,
      );
}

/// A channel resolved by `channel/<alias>`.
class ChannelHit {
  ChannelHit({
    required this.channelId,
    required this.name,
    required this.alias,
    required this.type,
    required this.isPrivate,
    this.description = '',
    required this.subscribersCount,
    required this.hasAccess,
    this.isSubscribed = false,
    this.myRole = '',
    this.communityId,
  });
  final String channelId;
  final String name;
  final String alias;
  final String type;
  final bool isPrivate;
  final String description;
  final int subscribersCount;
  final bool hasAccess;
  final bool isSubscribed;
  final String myRole;
  final String? communityId;

  String get address => addressOf(SearchTargetType.channel, alias);

  Channel toChannel() => Channel(
      id: channelId,
      name: name,
      type: type,
      alias: alias,
      isPrivate: isPrivate,
      description: description,
      communityId: communityId,
      role: myRole,
      subscribersCount: subscribersCount);

  factory ChannelHit.fromJson(Map<String, dynamic> j) => ChannelHit(
        channelId: j['channel_id'] as String,
        name: (j['name'] ?? '') as String,
        alias: (j['alias'] ?? '') as String,
        type: (j['channel_type'] ?? j['type'] ?? 'text') as String,
        isPrivate: (j['is_private'] ?? false) as bool,
        description: (j['description'] ?? '') as String,
        subscribersCount: (j['subscribers_count'] as num?)?.toInt() ?? 0,
        hasAccess: (j['has_access'] ?? false) as bool,
        isSubscribed: (j['is_subscribed'] ?? false) as bool,
        myRole: (j['my_role'] ?? '') as String,
        communityId: j['community_id'] as String?,
      );
}

/// Russian copy for search failures. Never surfaces raw backend codes.
String searchErrorText(SearchTargetType type, Object e) {
  if (e is GrchatException) {
    return switch (e.code) {
      'NOT_FOUND' => switch (type) {
        SearchTargetType.channel => 'Канал с таким кодом не найден.',
        SearchTargetType.server => 'Сервер с таким кодом не найден.',
        SearchTargetType.bot => 'Бот с таким кодом не найден.',
        SearchTargetType.user => 'Пользователь с таким никнеймом не найден.',
      },
      'BAD_ALIAS' || 'BAD_NICK' => 'Некорректный код.',
      'ALIAS_TAKEN' => 'Код занят, выбери другой.',
      'ALIAS_RESERVED' => 'Этот код зарезервирован.',
      'NEED_INVITE' => 'Приватный сервер: нужен инвайт.',
      'NEED_ACCESS' => 'Приватный канал: нет доступа.',
      'BANNED' => 'Доступ запрещён.',
      _ => 'Не удалось выполнить поиск. Проверьте соединение и попробуйте снова.',
    };
  }
  return 'Не удалось выполнить поиск. Проверьте соединение и попробуйте снова.';
}

/// Action labels for result cards.
String resultActionLabel(SearchTargetType type,
    {required bool joined, required bool isPrivate}) {
  return switch (type) {
    SearchTargetType.user => 'Написать',
    SearchTargetType.bot => 'Скоро',
    SearchTargetType.server =>
      joined ? 'Открыть' : (isPrivate ? 'Нужен инвайт' : 'Присоединиться'),
    SearchTargetType.channel =>
      joined ? 'Открыть' : (isPrivate ? 'Нет доступа' : 'Подписаться'),
  };
}
