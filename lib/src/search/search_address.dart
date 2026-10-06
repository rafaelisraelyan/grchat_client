/// Unified GRChat search addressing: `channel/<code>`, `server/<code>`,
/// `bot/<code>`, `user/<nickname>`.
///
/// The prefix is a presentation/addressing layer: state keeps `type` and
/// `query` separately, never `"channel/7F2K9A"` as a single string.
library;

/// What the user is looking for. `bot` is a first-class type so the
/// architecture never needs reshaping — it is only *inactive* in the UI
/// until the server ships a Bot API (no mocks, no fake actions).
enum SearchTargetType { channel, server, bot, user }

/// Parsed search address: type + bare identifier, no prefix stored.
typedef ParsedSearchAddress = ({SearchTargetType type, String query});

/// Prefix written before the editable query, e.g. `channel/`.
String prefixOf(SearchTargetType type) => '${type.name}/';

/// Full human-readable address, used for copy/share/paste.
String addressOf(SearchTargetType type, String query) =>
    '${prefixOf(type)}${query.trim()}';

/// Parses `channel/7F2K9A`-style input. Returns null for empty query,
/// unknown prefix, or malformed input. Prefix match is case-insensitive;
/// the query itself is never case-folded (nicknames may be significant).
ParsedSearchAddress? parseSearchAddress(String input) {
  final t = input.trim();
  if (t.isEmpty) return null;
  final slash = t.indexOf('/');
  if (slash <= 0) return null;
  if (t.indexOf('/', slash + 1) >= 0) return null;
  final type = SearchTargetType.values.asNameMap()[t
      .substring(0, slash)
      .toLowerCase()];
  if (type == null) return null;
  final query = t.substring(slash + 1).trim();
  if (query.isEmpty) return null;
  return (type: type, query: query);
}

/// Shared alias rules (mirrored by the server, which is authoritative):
/// 3–24 chars, letters/digits/underscore. Case-insensitive uniqueness
/// and reserved words are enforced by the backend.
bool isValidAlias(String alias) {
  final t = alias.trim();
  if (t.length < 3 || t.length > 24) return false;
  return RegExp(r'^[A-Za-z0-9_]+$').hasMatch(t);
}

/// System words that can never become a public alias.
const reservedAliases = {
  'admin',
  'administrator',
  'root',
  'system',
  'support',
  'help',
  'api',
  'grchat',
  'official',
  'channel',
  'channels',
  'server',
  'servers',
  'bot',
  'bots',
  'user',
  'users',
  'invite',
  'invites',
  'settings',
  'search',
  'find',
  'create',
  'open',
  'join',
  'null',
  'undefined',
  'everyone',
  'here',
  'all',
  'me',
};

/// True when the alias is free of reserved words (case-insensitive).
/// Uniqueness itself is checked by the backend (`ALIAS_TAKEN`).
bool isAllowedAlias(String alias) =>
    !reservedAliases.contains(alias.trim().toLowerCase());
