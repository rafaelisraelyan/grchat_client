import 'dart:io';

/// Cross-process camera ownership. Windows capture devices serve exactly
/// one grabber; two grchat instances racing getUserMedia both "open" the
/// device but receive no frames. A temp-file exclusive lock arbitrates:
/// the first instance that reaches a video call keeps the camera, the
/// other one opens audio/video-if-free and stays a receiver.
///
/// The lock is advisory between grchat instances only (other apps that do
/// not know about the file can still race Windows itself, exactly as
/// before); it exists to stop our own instances from stealing frames from
/// each other.
abstract final class CameraLock {
  static RandomAccessFile? _raf;

  static File get _file =>
      File('${Directory.systemTemp.path}${Platform.pathSeparator}'
          'grchat_camera.lock');

  /// Tries to take exclusive ownership. False = another grchat instance
  /// currently owns the camera path, use audio-only.
  static bool acquire() {
    if (_raf != null) return true; // already ours
    try {
      final raf = _file.openSync(mode: FileMode.write);
      raf.lockSync(FileLock.exclusive);
      _raf = raf;
      return true;
    } catch (_) {
      return false;
    }
  }

  static void release() {
    final raf = _raf;
    _raf = null;
    if (raf == null) return;
    try {
      raf.unlockSync();
    } catch (_) {}
    try {
      raf.closeSync();
    } catch (_) {}
    try {
      _file.deleteSync();
    } catch (_) {}
  }
}
