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
