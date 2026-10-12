/// Pure SDP helpers for the P2P path (no WebRTC imports: unit-testable).
library;

/// Opus parameters for high-quality voice calls. Each one is only added when
/// the fmtp line does not already carry that key, so a browser default or a
/// future explicit setting is never overridden.
///
/// The fmtp in OUR local description states what WE want to RECEIVE, so both
/// peers applying this makes the traffic symmetric:
/// - maxaveragebitrate=64000: 64 kbit/s mono full-band voice is close to
///   transparent (libwebrtc defaults to ~32 kbit/s when this is absent);
/// - maxplaybackrate / sprop-maxcapturerate=48000: full 48 kHz bandwidth,
///   no band-limiting;
/// - useinbandfec=1: forward error correction inside the stream;
/// - usedtx=0: continuous transmission. DTX saves almost nothing on a 1:1
///   link and can clip the first syllable after a pause;
/// - cbr=0: variable bitrate, better quality per bit;
/// - stereo=0 / sprop-stereo=0: a microphone is mono, stereo would waste
///   half the bits.
const opusFmtpDefaults = <String, String>{
  'useinbandfec': '1',
  'usedtx': '0',
  'maxaveragebitrate': '64000',
  'maxplaybackrate': '48000',
  'sprop-maxcapturerate': '48000',
  'cbr': '0',
  'stereo': '0',
  'sprop-stereo': '0',
};

/// Matching sender-side ceiling (bit/s) for the audio encoding.
const opusSenderMaxBitrate = 64000;

/// Adds [opusFmtpDefaults] to every Opus payload type in [sdp]. Returns the
/// input unchanged when there is no Opus line. Keeps the original line
/// endings (CRLF in real SDP).
String tuneOpusSdp(String sdp, {Map<String, String> params = opusFmtpDefaults}) {
  if (sdp.isEmpty) return sdp;
  final eol = sdp.contains('\r\n') ? '\r\n' : '\n';
  final lines = sdp.split(eol);

  final pts = <String>{};
  final rtpmap = RegExp(r'^a=rtpmap:(\d+) opus/48000(?:/2)?\s*$',
      caseSensitive: false);
  for (final l in lines) {
    final m = rtpmap.firstMatch(l);
    if (m != null) pts.add(m.group(1)!);
  }
  if (pts.isEmpty) return sdp;

  final out = <String>[];
  for (final l in lines) {
    final fm = RegExp(r'^a=fmtp:(\d+) (.*)$').firstMatch(l);
    if (fm != null && pts.contains(fm.group(1))) {
      out.add('a=fmtp:${fm.group(1)} ${_merge(fm.group(2)!, params)}');
      continue;
    }
    out.add(l);
    final rm = rtpmap.firstMatch(l);
    if (rm != null) {
      final pt = rm.group(1)!;
      // No fmtp line for this payload anywhere: add one right after rtpmap.
      final hasFmtp =
          lines.any((x) => x.startsWith('a=fmtp:$pt '));
      if (!hasFmtp) {
        out.add('a=fmtp:$pt ${_merge('', params)}');
      }
    }
  }
  return out.join(eol);
}

String _merge(String existing, Map<String, String> params) {
  final parts = existing
      .split(';')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final have = parts.map((e) => e.split('=').first.trim()).toSet();
  for (final e in params.entries) {
    if (!have.contains(e.key)) parts.add('${e.key}=${e.value}');
  }
  return parts.join(';');
}

/// Outgoing SDP tuning for P2P calls (both endpoints run this client).
///
/// Applies [tuneOpusSdp] (full Opus profile) and caps the video section
/// bandwidth at `b=AS:1500` (720p talking heads need no more; the cap
/// fights congestion collapse on weak uplinks). Pure string surgery, fully
/// unit-tested; a no-match input passes through byte-identical.
String tuneLocalSdp(String sdp) {
  final tunedAudio = tuneOpusSdp(sdp);
  return _capVideoBandwidth(tunedAudio, 1500);
}

String _capVideoBandwidth(String sdp, int kbps) {
  final lines = sdp.split('\n');
  final out = <String>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i].trim();
    if (!line.startsWith('m=video')) {
      out.add(lines[i]);
      i++;
      continue;
    }
    // One video section: gather to the next m= (or end), then transform.
    final section = <String>[lines[i]];
    i++;
    while (i < lines.length && !lines[i].trim().startsWith('m=')) {
      section.add(lines[i]);
      i++;
    }
    var replaced = false;
    for (var k = 0; k < section.length; k++) {
      if (section[k].trim().startsWith('b=AS:')) {
        section[k] = _restoreEol(section[k], 'b=AS:$kbps');
        replaced = true;
      }
    }
    if (!replaced) {
      final at = section.indexWhere((r) => r.trim().startsWith('a='));
      final cap = at >= 0 ? _restoreEol(section[at], 'b=AS:$kbps') : 'b=AS:$kbps';
      section.insert(at >= 0 ? at : section.length, cap);
    }
    out.addAll(section);
  }
  return out.join('\n');
}

/// Keeps the source line ending (\r\n vs \n) for the replacement.
String _restoreEol(String raw, String content) =>
    raw.endsWith('\r') ? '$content\r' : content;
