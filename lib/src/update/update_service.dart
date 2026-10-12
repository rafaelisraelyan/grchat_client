import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cg;
import 'package:riverpod/riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../call/call_diagnostics.dart';

/// Self-update from the public grchat-releases repo (anonymous GitHub API).
/// Stable channel tracks full releases, beta also takes prereleases.
enum UpdateChannel { release, beta }

class UpdateInfo {
  UpdateInfo(
      {required this.version,
      required this.tag,
      required this.url,
      required this.sizeBytes,
      required this.prerelease,
      this.sha256Url,
      this.sigUrl});
  final String version;
  final String tag;
  final String url;
  final int sizeBytes;
  final bool prerelease;

  /// URL of the `<asset>.sha256` sidecar, if the release published one.
  /// Integrity only (catches a corrupt download); it is NOT the trust gate,
  /// because it lives in the same release as the zip.
  final String? sha256Url;

  /// URL of the `<asset>.sig` Ed25519 signature (hex). The trust gate:
  /// no valid signature means no install.
  final String? sigUrl;
}

enum UpdateStatus { idle, checking, available, downloading, uptodate, error }

class UpdateUiState {
  const UpdateUiState(
      {this.status = UpdateStatus.idle,
      this.info,
      this.progress,
      this.message});
  final UpdateStatus status;
  final UpdateInfo? info;
  final double? progress;
  final String? message;
}

class UpdateCenter extends Notifier<UpdateUiState> {
  static const _releasesApi =
      'https://api.github.com/repos/rafaelisraelyan/grchat-releases/releases';
  static const _assetName = 'grchat_client-windows.zip';
  static const _channelKey = 'update_channel';

  /// Ed25519 public key (64 hex chars) that release zips must be signed
  /// with. Generate the pair with `dart run tool/sign_release.dart keygen`,
  /// paste the PUBLIC half here, keep the private half off GitHub.
  /// Empty = signing not configured yet: installs are refused (fail closed).
  static const updatePublicKeyHex = '';

  /// In-place install only exists on Windows (PowerShell + Expand-Archive).
  /// Other platforms see the version notice and fetch the dmg by hand.
  static bool get supportsInstall => Platform.isWindows;

  @override
  UpdateUiState build() => const UpdateUiState();

  Future<UpdateChannel> channel() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_channelKey) ?? 'release') == 'beta'
        ? UpdateChannel.beta
        : UpdateChannel.release;
  }

  Future<void> setChannel(UpdateChannel c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _channelKey, c == UpdateChannel.beta ? 'beta' : 'release');
    ref.invalidate(updateChannelProvider);
    state = const UpdateUiState();
  }

  Future<String> currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  Future<void> check() async {
    state = const UpdateUiState(status: UpdateStatus.checking);
    try {
      final ch = await channel();
      final rel = await _latestInfo(ch);
      if (rel == null) {
        state = const UpdateUiState(
            status: UpdateStatus.error, message: 'Релизов пока нет');
        return;
      }
      final cur = await currentVersion();
      if (_isNewer(rel.version, cur)) {
        state = UpdateUiState(status: UpdateStatus.available, info: rel);
      } else {
        state = const UpdateUiState(status: UpdateStatus.uptodate);
      }
    } catch (e) {
      // Raw exceptions never reach the UI; the detail goes to the log.
      dlog('update check failed: $e');
      state = const UpdateUiState(
          status: UpdateStatus.error,
          message: 'Не вышло проверить обновление');
    }
  }

  Future<void> downloadAndInstall() async {
    final info = state.info;
    if (info == null || !supportsInstall) return;
    state = UpdateUiState(
        status: UpdateStatus.downloading, info: info, progress: 0);
    try {
      final tmp = await Directory.systemTemp.createTemp('grchat_upd');
      final zip = File('${tmp.path}\\update.zip');
      await _download(info.url, zip, info.sizeBytes, (p) {
        state = UpdateUiState(
            status: UpdateStatus.downloading, info: info, progress: p);
      });
      if (!await _verify(zip, info)) {
        // The file is deleted: never leave an unverified zip lying around.
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
        state = UpdateUiState(
            status: UpdateStatus.error,
            info: info,
            message: 'Обновление не прошло проверку подписи');
        return;
      }
      await _apply(zip, info.version);
      // _apply exits the process; if we are still here it failed.
      state = UpdateUiState(
          status: UpdateStatus.error,
          info: info,
          message: 'Не вышло запустить установку');
    } catch (e) {
      dlog('update download failed: $e');
      state = UpdateUiState(
          status: UpdateStatus.error,
          info: info,
          message: 'Не вышло скачать обновление');
    }
  }

  Future<Map<String, dynamic>?> _latest(UpdateChannel ch) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(_releasesApi));
      req.headers.set('User-Agent', 'grchat-client');
      req.headers.set('Accept', 'application/vnd.github+json');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final list =
          jsonDecode(await resp.transform(utf8.decoder).join()) as List;
      for (final r in list) {
        final m = r as Map<String, dynamic>;
        final pre = (m['prerelease'] ?? false) as bool;
        if (ch == UpdateChannel.release && pre) continue;
        String? url;
        String? shaUrl;
        String? sigUrl;
        var size = 0;
        for (final a in (m['assets'] as List? ?? const [])) {
          final am = a as Map<String, dynamic>;
          if (am['name'] == _assetName) {
            url = am['browser_download_url'] as String?;
            size = (am['size'] as num?)?.toInt() ?? 0;
          } else if (am['name'] == '$_assetName.sha256') {
            shaUrl = am['browser_download_url'] as String?;
          } else if (am['name'] == '$_assetName.sig') {
            sigUrl = am['browser_download_url'] as String?;
          }
        }
        if (url == null) continue;
        final tag = (m['tag_name'] ?? '') as String;
        return {
          'version': _numbers(tag),
          'tag': tag,
          'url': url,
          'size': size,
          'pre': pre,
          'sha256': shaUrl,
          'sig': sigUrl,
        };
      }
      return null;
    } finally {
      client.close();
    }
  }

  Future<UpdateInfo?> _latestInfo(UpdateChannel ch) async {
    final m = await _latest(ch);
    if (m == null) return null;
    return UpdateInfo(
        version: m['version'] as String,
        tag: m['tag'] as String,
        url: m['url'] as String,
        sizeBytes: m['size'] as int,
        prerelease: m['pre'] as bool,
        sha256Url: m['sha256'] as String?,
        sigUrl: m['sig'] as String?);
  }

  /// Trust gate before executing anything: the zip is unpacked over the
  /// install dir and relaunched, so a swapped file is a code-exec vector.
  ///
  /// 1. The Ed25519 signature must verify against the key baked into this
  ///    build. No signature, no key, malformed or wrong signature = refuse
  ///    (fail closed). A sha256 sidecar alone proves nothing: whoever can
  ///    replace the zip in the release can replace the sidecar too.
  /// 2. If a sha256 sidecar is present it must also match (corruption
  ///    check on top of the signature).
  Future<bool> _verify(File zip, UpdateInfo info) async {
    final pub = parseHex(updatePublicKeyHex, 32);
    if (pub == null) {
      dlog('update refused: no valid public key configured in this build');
      return false;
    }
    final sigUrl = info.sigUrl;
    if (sigUrl == null || sigUrl.isEmpty) {
      dlog('update refused: release has no .sig asset');
      return false;
    }
    final sig = parseHex(await _fetchText(sigUrl), 64);
    if (sig == null) {
      dlog('update refused: signature malformed');
      return false;
    }
    final bytes = await zip.readAsBytes();
    if (!await verifySignature(data: bytes, signature: sig, publicKey: pub)) {
      dlog('update refused: signature does not verify');
      return false;
    }
    final shaUrl = info.sha256Url;
    if (shaUrl != null && shaUrl.isNotEmpty) {
      final expected =
          (await _fetchText(shaUrl)).split(RegExp(r'\s+')).first;
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expected)) {
        dlog('update sha sidecar malformed');
        return false;
      }
      final digest = sha256.convert(bytes).toString();
      if (digest.toLowerCase() != expected.toLowerCase()) {
        dlog('update sha mismatch');
        return false;
      }
    }
    return true;
  }

  /// Pure Ed25519 check (testable). False on any malformed input.
  static Future<bool> verifySignature(
      {required List<int> data,
      required List<int> signature,
      required List<int> publicKey}) async {
    if (publicKey.length != 32 || signature.length != 64) return false;
    try {
      return await cg.Ed25519().verify(
        data,
        signature: cg.Signature(signature,
            publicKey: cg.SimplePublicKey(publicKey,
                type: cg.KeyPairType.ed25519)),
      );
    } catch (_) {
      return false;
    }
  }

  /// Hex string of exactly [bytes] bytes → bytes, else null. Pure.
  static List<int>? parseHex(String s, int bytes) {
    final h = s.trim().split(RegExp(r'\s+')).first;
    if (h.length != bytes * 2 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(h)) {
      return null;
    }
    return [
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16)
    ];
  }

  Future<String> _fetchText(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'grchat-client');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      return (await resp.transform(utf8.decoder).join()).trim();
    } finally {
      client.close();
    }
  }

  Future<void> _download(
      String url, File dst, int total, void Function(double) onP) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'grchat-client');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final sink = dst.openWrite();
      var got = 0;
      await for (final List<int> chunk in resp) {
        got += chunk.length;
        sink.add(chunk);
        if (total > 0) onP((got / total).clamp(0.0, 1.0));
      }
      await sink.close();
    } finally {
      client.close();
    }
  }

  /// Builds the updater script. Pure (testable): all paths baked in, no
  /// Dart interpolation surprises at runtime — see update_service_test.
  static String buildApplyScript(
      {required int pid,
      required String zipPath,
      required String dir,
      required String exe,
      required String log}) {
    return '\$pid0 = $pid\n'
        '"START " + (Get-Date -Format o) + " pid=\$pid0" | Out-File -Append "$log"\n'
        'Wait-Process -Id \$pid0 -ErrorAction SilentlyContinue\n'
        'try {\n'
        '  foreach (\$p in (Get-Process grchat_client -ErrorAction SilentlyContinue)) {\n'
        '    if (\$p.Id -ne \$pid0) {\n'
        '      try {\n'
        '        if (\$p.Path -eq "$exe") {\n'
        '          Stop-Process -Id \$p.Id -Force -ErrorAction Stop\n'
        '          "STOPPED sibling " + \$p.Id | Out-File -Append "$log"\n'
        '        }\n'
        '      } catch {\n'
        '        "SIBLING-SKIP " + \$Error[0] | Out-File -Append "$log"\n'
        '      }\n'
        '    }\n'
        '  }\n'
        '} catch {\n'
        '  "SIBLING-SCAN-FAIL " + \$Error[0] | Out-File -Append "$log"\n'
        '}\n'
        'Start-Sleep -Seconds 2\n'
        'try {\n'
        '  Expand-Archive -Path "$zipPath" -DestinationPath "$dir" -Force -ErrorAction Stop\n'
        '  "OK " + (Get-Date -Format o) | Out-File -Append "$log"\n'
        '} catch {\n'
        '  "FAIL " + \$Error[0] | Out-File -Append "$log"\n'
        '}\n'
        'Start-Process "$exe" -WorkingDirectory "$dir"\n'
        'Remove-Item "$zipPath" -Force -ErrorAction SilentlyContinue\n'
        'Remove-Item \$PSCommandPath -Force -ErrorAction SilentlyContinue\n';
  }

  /// Two-stage Windows install: a ps1 script waits for this process to
  /// exit, unpacks the bundle over the install dir and restarts the app.
  ///
  /// Hardened after two silent failures:
  /// - 1.4.0→1.5.0: a sibling client locked the install dir, killing
  ///   Expand-Archive with no trace. The script now stops siblings and
  ///   logs every step to apply.log.
  /// - 1.5.1→1.5.2: `ProcessStartMode.detached` children never execute
  ///   on this Dart/Windows setup (proven by spawn probes: attached runs,
  ///   detached is dead on arrival, with or without parent exit). The
  ///   updater is therefore launched via `cmd /c start` (a real
  ///   daemonize), which provably survives the parent.
  /// Daemonize argv for the updater script. Pure (testable).
  ///
  /// Two hard-won rules live here:
  /// - launch goes through `cmd /c start`: Dart's detached children never
  ///   execute on this setup (proven by spawn probes), while a `start`ed
  ///   grandchild provably survives the parent exit;
  /// - the script path stays BARE: Dart quotes argv with spaces itself,
  ///   and pre-quoted paths get mangled into `"""..."""`, which kills the
  ///   launch silently (proven by the sim: quoted died, bare lived).
  static List<String> updaterArgv(String scriptPath) => [
        '/c',
        'start',
        '""',
        'powershell.exe',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptPath,
      ];

  Future<void> _apply(File zip, String version) async {
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    final tmpDir = zip.parent.path;
    final script = File('$tmpDir\\apply.ps1');
    final log = '$tmpDir\\apply.log';
    await script.writeAsString(
        buildApplyScript(
            pid: pid,
            zipPath: zip.path,
            dir: dir,
            exe: exe,
            log: log),
        flush: true);
    dlog('update applying $version over $dir');
    await Process.start('cmd.exe', updaterArgv(script.path));
    exit(0);
  }

  static String _numbers(String tag) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(tag);
    return m == null ? '0.0.0' : '${m[1]}.${m[2]}.${m[3]}';
  }

  /// Test seam for the release gate (see test/update_service_test.dart).
  static String numbersForTest(String tag) => _numbers(tag);

  /// Test seam for the release gate (see test/update_service_test.dart).
  static bool isNewerForTest(String remote, String current) =>
      _isNewer(remote, current);

  static bool _isNewer(String remote, String current) {
    List<int> parts(String v) =>
        v.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final r = parts(remote);
    final c = parts(current);
    for (var i = 0; i < 3; i++) {
      final a = i < r.length ? r[i] : 0;
      final b = i < c.length ? c[i] : 0;
      if (a != b) return a > b;
    }
    return false;
  }
}

final updateCenterProvider =
    NotifierProvider<UpdateCenter, UpdateUiState>(UpdateCenter.new);

final updateChannelProvider =
    FutureProvider<UpdateChannel>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getString('update_channel') ?? 'release') == 'beta'
      ? UpdateChannel.beta
      : UpdateChannel.release;
});
