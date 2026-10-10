import 'package:livekit_client/livekit_client.dart';

/// Shared LiveKit room options for group calls and voice channels.
///
/// - dynacast: the SFU pauses video layers nobody consumes — less publish
///   CPU and uplink on multi-peer calls, applied server-side (1.13+).
/// - adaptiveStream: subscribers drop to the layer that fits their view
///   instead of always pulling full 720p.
/// Audio capture already ships AEC/NS/AGC/high-pass by default; camera
/// defaults to 720p. Pure constructor, no media side effects.
RoomOptions grchatRoomOptions() => const RoomOptions(
      dynacast: true,
      adaptiveStream: true,
    );
