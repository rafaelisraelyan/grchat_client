import 'package:livekit_client/livekit_client.dart';

/// Single place for LiveKit room tuning (group calls and voice channels).
///
/// - adaptiveStream: subscribers request only the resolution their tile
///   actually renders, so a thumbnail never pulls a 720p layer.
/// - dynacast: publishers stop sending simulcast layers nobody subscribes
///   to, which saves uplink and server egress.
/// Both are OFF by default in livekit_client, so they must be set here.
/// Simulcast publishing stays on (the package default).
///
/// E2EE hooks in here later via `e2eeOptions` (shared room key).
Room newRoom() => Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
      ),
    );
