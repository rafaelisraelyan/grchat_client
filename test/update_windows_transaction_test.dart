import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/update/update_service.dart';

Future<ProcessResult> powerShell(String script, List<String> args) =>
    Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'RemoteSigned',
      '-File',
      script,
      ...args,
    ], workingDirectory: File(script).parent.path);

void main() {
  test(
    'Windows update fixtures stage safely and restore a failed launch',
    () async {
      final root = await Directory.systemTemp.createTemp('grchat-r1-updater-');
      addTearDown(() => root.delete(recursive: true));
      String path(String relative) => '${root.path}\\$relative';
      const exe = 'grchat_client.exe';
      final fixture = await File(path('fixture.ps1')).writeAsString(r'''
param($Root)
$ErrorActionPreference = 'Stop'
$old = Join-Path $Root 'install'
$new = Join-Path $Root 'bundle'
New-Item -ItemType Directory -Path $old, (Join-Path $new 'data\flutter_assets') | Out-Null
$source = @"
using System.Reflection;
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0.0")]
public static class PreviousBuild { public static void Main() {} }
"@
Add-Type -TypeDefinition $source -OutputType WindowsApplication -OutputAssembly (Join-Path $old 'grchat_client.exe')
$source = @"
using System.Reflection;
[assembly: AssemblyFileVersion("2.0.0.0")]
[assembly: AssemblyInformationalVersion("2.0.0")]
public static class FailedBuild { public static int Main() { return 9; } }
"@
Add-Type -TypeDefinition $source -OutputType WindowsApplication -OutputAssembly (Join-Path $new 'grchat_client.exe')
Set-Content -LiteralPath (Join-Path $old 'old.marker') -Value 'previous installation'
Set-Content -LiteralPath (Join-Path $new 'flutter_windows.dll') -Value 'fixture'
Set-Content -LiteralPath (Join-Path $new 'data\icudtl.dat') -Value 'fixture'
Set-Content -LiteralPath (Join-Path $new 'data\flutter_assets\fixture') -Value 'fixture'
New-Item -ItemType Directory -Path (Join-Path $Root 'valid'), (Join-Path $Root 'missing'), (Join-Path $Root 'corrupt') | Out-Null
Compress-Archive -Path (Join-Path $new '*') -DestinationPath (Join-Path $Root 'valid\update.zip')
Compress-Archive -Path (Join-Path $new 'data') -DestinationPath (Join-Path $Root 'missing\update.zip')
Set-Content -LiteralPath (Join-Path $Root 'corrupt\update.zip') -Value 'not an archive'
''');
      final setup = await powerShell(fixture.path, [root.path]);
      expect(setup.exitCode, 0, reason: '${setup.stderr}');
      Future<String> updater(String id, {String version = '2.0.0'}) async {
        final script = File(path('$id\\apply.ps1'));
        await script.writeAsString(
          UpdateCenter.buildApplyScript(
            pid: 2147483647,
            zipPath: path('$id\\update.zip'),
            dir: path('install'),
            exe: path('install\\$exe'),
            log: path('$id\\apply.log'),
            version: version,
          ),
        );
        return script.path;
      }

      for (final id in ['missing', 'corrupt']) {
        final rejected = await powerShell(await updater(id), ['-StageOnly']);
        expect(rejected.exitCode, 1, reason: id);
        expect(File(path('install\\old.marker')).existsSync(), isTrue);
      }
      final valid = await updater('valid');
      expect(
        (await powerShell(valid, ['-StageOnly'])).exitCode,
        0,
        reason: File(path('valid\\apply.log')).readAsStringSync(),
      );
      expect(
        (await powerShell(valid, ['-StageOnly'])).exitCode,
        1,
        reason: 'same attempt may not overwrite the validated stage',
      );
      expect(File(path('install\\old.marker')).existsSync(), isTrue);
      final blockedBackup = await Directory(path('install.grchat-backup-valid'))
          .create();
      final blocked = await powerShell(valid, []);
      expect(
        blocked.exitCode,
        1,
        reason: 'activation cannot overwrite a backup',
      );
      expect(File(path('install\\old.marker')).existsSync(), isTrue);
      expect(
        File(path('install.grchat-stage-valid\\$exe')).existsSync(),
        isTrue,
      );
      await blockedBackup.delete();

      final launched = await powerShell(valid, []);
      expect(launched.exitCode, 1);
      expect(File(path('install\\old.marker')).existsSync(), isTrue);
      expect(
        File(path('install.grchat-failed-valid\\$exe')).existsSync(),
        isTrue,
      );
      expect(
        File(path('valid\\apply.log')).readAsStringSync(),
        contains('ROLLBACK restored previous directory'),
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
