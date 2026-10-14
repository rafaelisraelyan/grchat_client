// The default-device rule, the low-fps banner decision (§switch-banner
// and §default-camera, 2026-10-13) and the capture-learning reset on a
// device switch. Pure pieces, no platform channels.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grchat_client/src/call/call_state.dart';
import 'package:grchat_client/src/call/camera_notice.dart';
import 'package:grchat_client/src/call/quality_tier.dart';
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

  group('camera rescue walk (§dial-camera-walk)', () {
    final hd = (id: 'hd', label: 'HD Webcam');
    final bc = (id: 'bc', label: 'Camera (NVIDIA Broadcast)');
    final obs = (id: 'obs', label: 'OBS Virtual Camera');

    test('the failed device is skipped, physical ones come first', () {
      // Both remaining devices are virtual (Broadcast output, OBS), so
      // the enumeration order between them is kept.
      expect(
        MediaPrefs.walkOrderFrom([obs, hd, bc], 'hd').map((d) => d.id),
        ['obs', 'bc'],
      );
    });

    test('order is physical-first regardless of enumeration order', () {
      expect(
        MediaPrefs.walkOrderFrom([obs, bc, hd], null).map((d) => d.id),
        ['hd', 'obs', 'bc'],
      );
    });

    test('privacy / black-hole cameras go LAST (2026-10-14)', () {
      // AMD Privacy View delivers synthetic black at ~465 fps: a walk that
      // "rescues" the call onto it shows the peer a black screen that looks
      // like a UI bug. Real cameras first, then ordinary virtual ones.
      final pv = (id: 'pv', label: 'AMD Privacy View camera');
      final dazzle = (id: 'dz', label: 'Dazzle Cam');
      expect(
        MediaPrefs.walkOrderFrom([pv, hd, bc, dazzle], 'hd').map((d) => d.id),
        ['bc', 'pv', 'dz'],
      );
      expect(MediaPrefs.looksBlackHole('AMD Privacy View camera'), isTrue);
      expect(MediaPrefs.looksBlackHole('Dazzle Cam'), isTrue);
      expect(MediaPrefs.looksBlackHole('HD Webcam'), isFalse);
      expect(MediaPrefs.looksBlackHole('OBS Virtual Camera'), isFalse);
    });

    test('capped, so a shelf of dead devices cannot eat the dial time', () {
      final many = [
        (id: 'a', label: 'A'),
        (id: 'b', label: 'B'),
        (id: 'c', label: 'C'),
        (id: 'd', label: 'D'),
        (id: 'e', label: 'E'),
      ];
      expect(MediaPrefs.walkOrderFrom(many, null).map((d) => d.id), [
        'a',
        'b',
        'c',
      ]);
    });
  });

  group('probe ladder stop rule (§dial-camera-walk)', () {
    test('an open with NO frames stops the sweep (device-level failure)', () {
      expect(
        CallState.ladderShouldStop(
          frameArrived: false,
          frameless: 2,
          budget: 2,
        ),
        isTrue,
      );
    });

    test('the first frameless open still gets its budget of tries', () {
      expect(
        CallState.ladderShouldStop(
          frameArrived: false,
          frameless: 1,
          budget: 2,
        ),
        isFalse,
      );
    });

    test('frames below the ask keep the ladder going (profile problem)', () {
      expect(
        CallState.ladderShouldStop(
          frameArrived: true,
          frameless: 2,
          budget: 2,
        ),
        isFalse,
      );
    });
  });

  group('probe log fingerprint (readable device ids)', () {
    test('short ids stay whole, long USB paths get trimmed', () {
      expect(CallState.shortDevice('Camera (NVIDIA Broadcast)'),
          'Camera (NVIDIA Broadcast)');
      expect(CallState.shortDevice(null), 'default');
      expect(CallState.shortDevice(''), 'default');
      const usb =
          r'\\?\usb#vid_04f2&pid_b78a&mi_00#8&19976506&0&0000'
          r'#{65e8773d-8f56-11d0-a3b9-00a0c9223196}\global';
      final short = CallState.shortDevice(usb);
      expect(short.length, lessThan(usb.length));
      expect(short, startsWith(r'\\?\usb#vid_04f2&pid_b78'));
      expect(short, endsWith('}\\global'));
    });
  });

  group('remote camera watchdog (§remote-mute)', () {
    test('a flowing stream never trips the watch', () {
      final w = RemoteVideoWatch();
      expect(w.update(inboundBytes: 1000, expectVideo: true), isFalse);
      expect(w.update(inboundBytes: 5000, expectVideo: true), isFalse);
      expect(w.update(inboundBytes: 9000, expectVideo: true), isFalse);
      expect(w.gone, isFalse);
    });

    test('frozen counters flip it to gone exactly once', () {
      final w = RemoteVideoWatch(staleTicks: 2);
      expect(w.update(inboundBytes: 1000, expectVideo: true), isFalse);
      expect(w.update(inboundBytes: 1000, expectVideo: true), isFalse);
      expect(w.gone, isFalse, reason: 'one stale tick must not flip it');
      expect(w.update(inboundBytes: 1000, expectVideo: true), isTrue);
      expect(w.gone, isTrue);
      expect(
        w.update(inboundBytes: 1000, expectVideo: true),
        isFalse,
        reason: 'the verdict is reported once, not every tick',
      );
    });

    test('inbound video coming back clears it', () {
      final w = RemoteVideoWatch(staleTicks: 1);
      w.update(inboundBytes: 1000, expectVideo: true);
      expect(w.update(inboundBytes: 1000, expectVideo: true), isTrue);
      expect(w.gone, isTrue);
      expect(w.update(inboundBytes: 4000, expectVideo: true), isTrue);
      expect(w.gone, isFalse);
    });

    test('no inbound report at all never judges (safe default)', () {
      final w = RemoteVideoWatch(staleTicks: 1);
      for (var i = 0; i < 5; i++) {
        expect(w.update(inboundBytes: null, expectVideo: true), isFalse);
      }
      expect(w.gone, isFalse);
    });

    test('a call without remote video resets the baseline', () {
      final w = RemoteVideoWatch(staleTicks: 1);
      w.update(inboundBytes: 1000, expectVideo: true);
      expect(w.update(inboundBytes: 1000, expectVideo: true), isTrue);
      expect(w.gone, isTrue);
      // The call has no remote video (peer never enabled): clear, silently.
      expect(w.update(inboundBytes: 1000, expectVideo: false), isTrue);
      expect(w.gone, isFalse);
      expect(w.update(inboundBytes: 1000, expectVideo: false), isFalse);
    });
  });

  group('60 fps is the hard camera ceiling (owner, 2026-10-14)', () {
    test('the constant is the single source of truth', () {
      expect(kMaxCameraFps, 60);
    });

    test('a synthetic 465 fps reading never becomes a tier ceiling', () {
      expect(CallState.sanitizeObservedFps(465), -1);
      expect(CallState.sanitizeObservedFps(61), -1);
      expect(CallState.sanitizeObservedFps(60), 60);
      expect(CallState.sanitizeObservedFps(29.5), 29.5);
      expect(CallState.sanitizeObservedFps(-1), -1);
      // A missing sample (0) is passed through: the learner decides.
      expect(CallState.sanitizeObservedFps(0), 0);
    });

    test('tier params never ask the sender for more than 60 fps', () {
      // A black-hole camera reports 465 fps and outranks the max tier by
      // capture rate - the ceiling must still hold at 60.
      final p = tierParams(
        videoTiers.last,
        captureHeight: 1080,
        captureFps: 465,
      );
      expect(p.maxFramerate, 60);
      final honest = tierParams(
        videoTiers[2],
        captureHeight: 1080,
        captureFps: 30,
      );
      expect(honest.maxFramerate, 30);
      final top = tierParams(
        videoTiers.last,
        captureHeight: 1080,
        captureFps: 60,
      );
      expect(top.maxFramerate, 60);
    });

    test('the learner refuses to commit a bogus floor', () {
      final learn = FpsCapLearn();
      learn.update(465, tierFps: 60);
      learn.update(465, tierFps: 60);
      expect(learn.cap, 0, reason: 'a synthetic source must not floor the tier');
      // A real 11 fps camera still commits its floor.
      learn.update(11, tierFps: 60);
      learn.update(11, tierFps: 60);
      expect(learn.cap, 11);
    });
  });
}
