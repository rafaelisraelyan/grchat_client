// The default-device rule, the low-fps banner decision (§switch-banner
// and §default-camera, 2026-10-13) and the capture-learning reset on a
// device switch. Pure pieces, no platform channels.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/camera_notice.dart';
import 'package:grchat_client/src/media/media_prefs.dart';

void main() {
  group('camera default rule (first PHYSICAL)', () {
    final hd = (id: 'hd', label: 'HD Webcam');
    final obs = (id: 'obs', label: 'OBS Virtual Camera');
    final bc = (id: 'bc', label: 'Camera (NVIDIA Broadcast)');
    final pv = (id: 'pv', label: 'AMD Privacy View camera');
    final virtualOnly = (id: 'obs2', label: 'Virtual Camera');

    test(
      'physical first, virtual never as a default while physical exists',
      () {
        expect(MediaPrefs.defaultDeviceIdFrom([obs, hd, bc, pv]), 'hd');
        // Marker order in the list does not promote OBS.
        expect(MediaPrefs.defaultDeviceIdFrom([obs, bc, hd]), 'hd');
      },
    );

    test('all marker spellings are recognized case-insensitively', () {
      for (final label in [
        'OBS Virtual Camera',
        'camera virtual',
        'NVIDIA Broadcast',
        'Snap Camera',
        'ManyCam',
        'XSplit VCam',
        'DroidCam Client',
        'camo',
        'AMD Privacy View camera',
      ]) {
        expect(MediaPrefs.looksVirtual(label), isTrue, reason: 'label: $label');
      }
    });

    test('a false-positive label still keeps the rules honest', () {
      expect(MediaPrefs.looksVirtual('HD Webcam'), isFalse);
    });

    test('no physical camera -> whatever is there', () {
      expect(MediaPrefs.defaultDeviceIdFrom([obs, virtualOnly]), 'obs');
    });

    test('no cameras at all -> null', () {
      expect(MediaPrefs.defaultDeviceIdFrom(const []), isNull);
    });
  });

  group('low-fps banner decision (pure)', () {
    test('shows for a low ceiling with video on and no share', () {
      expect(
        shouldShowCameraCapNotice(
          capFps: 10,
          videoOn: true,
          sharing: false,
          alreadyShown: false,
          hasOtherCameras: true,
        ),
        isTrue,
      );
      expect(
        shouldShowCameraCapNotice(
          capFps: 20,
          videoOn: true,
          sharing: false,
          alreadyShown: false,
          hasOtherCameras: false,
        ),
        isTrue,
        reason: 'the threshold is <= 20',
      );
    });

    test('a healthy camera (over 20) never banners', () {
      expect(
        shouldShowCameraCapNotice(
          capFps: 21,
          videoOn: true,
          sharing: false,
          alreadyShown: false,
          hasOtherCameras: true,
        ),
        isFalse,
      );
    });

    test('camera off, screen share, already shown - silent', () {
      for (final (videoOn, sharing, shown) in [
        (true, true, false), // share owns the sender
        (false, false, false), // capture-less state
        (true, false, true), // once per call
      ]) {
        expect(
          shouldShowCameraCapNotice(
            capFps: 10,
            videoOn: videoOn,
            sharing: sharing,
            alreadyShown: shown,
            hasOtherCameras: true,
          ),
          isFalse,
          reason: 'videoOn=$videoOn sharing=$sharing shown=$shown',
        );
      }
    });
  });

  group('capture learning reset on a device switch (§switch-camera)', () {
    test('resetCaptureLearning zeroes the learned ceiling and height', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final st = container.read(callStateProvider.notifier);

      st.debugLearnCapture(capFps: 11, height: 1080);
      expect(st.cameraFpsCapValue, 11);
      expect(st.captureHeightValue, 1080);

      st.resetCaptureLearning();

      expect(st.cameraFpsCapValue, 0);
      expect(st.captureHeightValue, 0);
    });
  });
}
