import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grchat_client/src/transport/grchat_connection.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart';

const _port = int.fromEnvironment('GRCHAT_STAGE2B_PORT');
const _ca = String.fromEnvironment('GRCHAT_STAGE2B_CA');
const _mail = String.fromEnvironment('GRCHAT_STAGE2B_MAIL_FIXTURE');
const _mediaCa = String.fromEnvironment('GRCHAT_R1_MEDIA_CA');

class _FixtureTrust extends HttpOverrides {
  _FixtureTrust(this.context);
  final SecurityContext context;

  @override
  HttpClient createHttpClient(SecurityContext? _) =>
      super.createHttpClient(context);
}

class _Peer {
  _Peer(this.connection);
  final GrchatConnection connection;
  String? token;
  late String userId;

  Future<Map<String, dynamic>> request(
    String command,
    String expected, [
    Map<String, dynamic> fields = const {},
  ]) async {
    final result = await connection.request(
      command,
      fields: {if (token != null) 'session_token': token, ...fields},
    );
    expect(result['type'], expected, reason: '$command (${result['code']})');
    return result;
  }

  Future<void> register(String nick) async {
    final email = '$nick@r1-fixture.invalid';
    const password = 'test-fixture-only123';
    await connection.connect('127.0.0.1', _port);
    await request('register', 'register_ok', {
      'nick': nick,
      'email': email,
      'password': password,
    });
    final line = File(_mail)
        .readAsLinesSync()
        .lastWhere((row) => row.startsWith('$email\t'));
    await request('verify_email', 'verify_ok', {
      'email': email,
      'code': line.split('\t').last,
    });
    final login = await request('login', 'login_ok', {
      'login': nick,
      'password': password,
    });
    token = login['session_token'] as String;
    userId = login['user_id'] as String;
  }
}

Track? _track(Room room, bool audio) {
  for (final participant in room.remoteParticipants.values) {
    final tracks = audio
        ? participant.audioTrackPublications
        : participant.videoTrackPublications;
    for (final publication in tracks) {
      if (publication.track != null) return publication.track;
    }
  }
  return null;
}

Future<int> _packets(Track? track) async {
  final stats = await track?.receiver?.getStats();
  return stats
          ?.where((report) => report.type == 'inbound-rtp')
          .fold<int>(
            0,
            (total, report) =>
                total +
                ((report.values['packetsReceived'] as num?)?.toInt() ?? 0),
          ) ??
      0;
}

Future<bool> _until(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'R1 native SFU publishes and receives RTP and enforces microphone mute',
    () async {
      expect(
        _port,
        greaterThan(0),
        reason: 'use the isolated R1 media fixture',
      );
      final tls = devTrustContext(isDebug: true, caPath: _ca);
      final mediaTrust = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificatesBytes(File(_mediaCa).readAsBytesSync());
      GrchatConnection connect() => GrchatConnection(
        connector: (host, port) =>
            SecureSocket.connect(host, port, context: tls),
      );
      final a = _Peer(connect());
      final b = _Peer(connect());
      final publisher = Room();
      final subscriber = Room();
      final suffix = DateTime.now().millisecondsSinceEpoch % 100000000;
      String? joined;
      bool subscriberJoined = false;
      try {
        await a.register('r1sfua$suffix');
        await b.register('r1sfub$suffix');
        final community = await a.request(
          'create_community',
          'community_created',
          {'name': 'R1 isolated SFU'},
        );
        final scope = {'community_id': community['community_id']};
        final channel = await a.request('create_channel', 'channel_created', {
          ...scope,
          'name': 'Voice',
          'channel_type': 'voice',
        });
        final voice = {'channel_id': channel['channel_id']};
        final invite = await a.request(
          'create_invite',
          'invite_created',
          scope,
        );
        await b.request('join_by_invite', 'invite_accepted', {
          'code': invite['code'],
        });
        await a.request('voice_join', 'voice_joined_ok', voice);
        joined = channel['channel_id'] as String;
        await b.request('voice_join', 'voice_joined_ok', voice);
        subscriberJoined = true;
        final pub = await a.request('voice_token', 'voice_token', voice);
        final sub = await b.request('voice_token', 'voice_token', voice);

        await HttpOverrides.runWithHttpOverrides(() async {
          await publisher.connect(pub['url'] as String, pub['token'] as String);
          await subscriber.connect(
            sub['url'] as String,
            sub['token'] as String,
          );
        }, _FixtureTrust(mediaTrust));
        final local = publisher.localParticipant!;
        expect(await local.setMicrophoneEnabled(true), isNotNull);
        expect(await local.setCameraEnabled(true), isNotNull);
        expect(
          await _until(
            () async =>
                await _packets(_track(subscriber, true)) > 3 &&
                await _packets(_track(subscriber, false)) > 3,
          ),
          isTrue,
        );
        final audioBefore = await _packets(_track(subscriber, true));
        final videoBefore = await _packets(_track(subscriber, false));
        await Future<void>.delayed(const Duration(milliseconds: 850));
        final audioAfter = await _packets(_track(subscriber, true));
        final videoAfter = await _packets(_track(subscriber, false));
        expect(audioAfter, greaterThan(audioBefore));
        expect(videoAfter, greaterThan(videoBefore));

        await a.request('voice_mute', 'voice_mute_ok', {
          ...voice,
          'user_id': a.userId,
          'muted': true,
        });
        expect(
          await _until(() async => _track(subscriber, true) == null),
          isTrue,
          reason: 'SFU must unpublish the microphone without client mute',
        );
        final videoAfterMute = await _packets(_track(subscriber, false));
        expect(
          await _until(
            () async =>
                await _packets(_track(subscriber, false)) > videoAfterMute,
          ),
          isTrue,
          reason: 'server mic mute must preserve camera RTP',
        );
        // ignore: avoid_print
        print(
          'R1 SFU RTP audio $audioBefore->$audioAfter, '
          'video $videoBefore->$videoAfter; microphone unpublished by SFU',
        );
      } finally {
        await subscriber.dispose();
        await publisher.dispose();
        if (joined != null) {
          final scope = {'channel_id': joined};
          try {
            if (subscriberJoined) {
              await b.request('voice_leave', 'voice_left_ok', scope);
            }
            await a.request('voice_leave', 'voice_left_ok', scope);
          } finally {
            await a.connection.dispose();
            await b.connection.dispose();
          }
        } else {
          await a.connection.dispose();
          await b.connection.dispose();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
