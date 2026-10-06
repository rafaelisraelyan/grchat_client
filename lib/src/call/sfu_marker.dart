/// SFU invite marker carried in the stock `call_offer`/`call_answer` sdp
/// field for group calls: `livekit:<room>[:m=video]`.
///
/// Zero protocol changes: the server already fans group `dm_id` offers out
/// to online members. Clients that understand the marker join the LiveKit
/// room instead of doing P2P SDP; anything older fails the SDP parse and
/// cleans up. The `m=video` suffix keeps server call records accurate
/// (it derives video from the sdp text).
library;

/// Builds the invite marker for [room]. [video] appends the m=video flag.
String buildSfuMarker(String room, bool video) =>
    video ? 'livekit:$room:m=video' : 'livekit:$room';

/// Parses an SFU marker, or null for regular P2P SDP.
({String room, bool video})? parseSfuMarker(String sdp) {
  if (!sdp.startsWith('livekit:')) return null;
  final rest = sdp.substring('livekit:'.length);
  if (rest.isEmpty) return null;
  final idx = rest.indexOf(':');
  final room = idx < 0 ? rest : rest.substring(0, idx);
  if (room.isEmpty) return null;
  return (room: room, video: rest.contains('m=video'));
}

/// Canonical SFU room for a group DM. Mirrors the server.
String sfuRoomForDm(String dmId) => 'grchat_$dmId';
