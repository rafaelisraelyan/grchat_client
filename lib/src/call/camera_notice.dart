// Low-fps camera notice (§switch-banner): a pure decision + the banner
// payload. The SOURCE of the number is FpsCapLearn's capture fps ceiling
// (the commit after two stable ticks below the tier rate) - no second
// metric invented for the banner.
import 'package:riverpod/riverpod.dart';

/// Banner payload: what is wrong and whether another camera exists to
/// blame-and-fix through the settings section.
class CameraCapBanner {
  const CameraCapBanner({
    required this.capFps,
    required this.withSettingsButton,
  });

  final int capFps;
  final bool withSettingsButton;
}

/// The pure gate (§switch-banner): the capture ceiling is low, the local
/// camera is actually capturing (video on, not camera-off), no screen
/// share owns the video sender, and this call has not seen the banner.
/// [hasOtherCameras] picks the TEXT variant (settings hint vs light hint)
/// but never flips the verdict by itself.
bool shouldShowCameraCapNotice({
  required int capFps,
  required bool videoOn,
  required bool sharing,
  required bool alreadyShown,
  required bool hasOtherCameras,
}) {
  return capFps > 0 && capFps <= 20 && videoOn && !sharing && !alreadyShown;
}

/// Why a camera open failed (§camera-busy). The distinction matters to the
/// user AND to safety: [anotherInstance] must never be worked around,
/// because grabbing a device a second grchat window already streams from
/// kills that window's call (measured 2026-10-14: the peer's ICE dropped 56
/// ms after a second grabber opened `Camera (NVIDIA Broadcast)`).
enum CameraBlock {
  /// No failure was recorded.
  none,

  /// PROVEN: our own cross-process lock is held by another grchat window.
  anotherInstance,

  /// PROVEN by the native error: the OS refused access (privacy setting).
  permissions,

  /// The device opened but delivered NOTHING. We do NOT know who holds it —
  /// a foreign app is a plausible guess and must be phrased as one.
  deviceDead,
}

/// The user-facing text for a blocked camera (§camera-busy). Pure so the
/// wording is testable and identical on every path (late enable, dial,
/// device switch). Rule of the product: state a reason only when we can
/// prove it; otherwise hedge.
String cameraBlockNotice(CameraBlock block) {
  switch (block) {
    case CameraBlock.anotherInstance:
      return 'Камера занята другим окном grchat';
    case CameraBlock.permissions:
      return 'Нет доступа к камере. Проверьте разрешения системы.';
    case CameraBlock.deviceDead:
      return 'Не удалось включить камеру. Возможно, она используется другим '
          'приложением.';
    case CameraBlock.none:
      return 'Не удалось включить камеру.';
  }
}

/// Classifies a native capture error. Only an explicit access/permission
/// denial becomes [CameraBlock.permissions]; everything else stays
/// unproven, because claiming «занята другим приложением» without evidence
/// sends the user chasing the wrong process.
CameraBlock classifyCaptureError(String? error) {
  final e = (error ?? '').toLowerCase();
  final denied = e.contains('access denied') ||
      e.contains('permission') ||
      e.contains('access is denied') ||
      e.contains('0x80070005') ||
      e.contains('privacy');
  return denied ? CameraBlock.permissions : CameraBlock.none;
}

/// Per-call banner state: shown once, hidden by the user's close button or
/// by the call teardown.
class CameraCapBannerState extends Notifier<CameraCapBanner?> {
  @override
  CameraCapBanner? build() => null;

  void show(CameraCapBanner banner) {
    state = banner;
  }

  void hide() {
    state = null;
  }
}

final cameraCapBannerProvider =
    NotifierProvider<CameraCapBannerState, CameraCapBanner?>(
      CameraCapBannerState.new,
    );
