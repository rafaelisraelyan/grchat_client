/// Outgoing SDP tuning for P2P calls (both endpoints run this client).
///
/// Two contained munges, applied to our local offer/answer before
/// setLocalDescription — never to remote SDP, never to signaling logic:
/// - Opus: pin `maxaveragebitrate=32000` + `useinbandfec=1`. Voice stays
///   full quality while the uplink stops bursting; FEC rides out loss.
///   DTX stays off: it clips first syllables after silence.
/// - Video: cap the section bandwidth at `b=AS:1500` (720p talking heads
///   need no more; the cap fights congestion collapse on weak uplinks).
/// Pure string surgery, fully unit-tested; a no-match input passes
/// through byte-identical.
String tuneLocalSdp(String sdp) {
  final tunedAudio = _tuneOpus(sdp);
  return _capVideoBandwidth(tunedAudio, 1500);
}

String _tuneOpus(String sdp) {
  final lines = sdp.split('\n');
  var inAudio = false;
  var opusPt = '';
  for (final raw in lines) {
    final line = raw.trim();
    if (line.startsWith('m=audio')) {
      inAudio = true;
      continue;
    }
    if (line.startsWith('m=')) {
      inAudio = false;
      continue;
    }
    if (inAudio && opusPt.isEmpty) {
      final m = RegExp(r'^a=rtpmap:(\d+)\s+opus/48000', caseSensitive: false)
          .firstMatch(line);
      if (m != null) opusPt = m.group(1)!;
    }
  }
  if (opusPt.isEmpty) return sdp;
  final out = <String>[];
  var fmtpDone = false;
  for (final raw in lines) {
    final line = raw.trim();
    if (!fmtpDone && line.startsWith('a=fmtp:$opusPt')) {
      var params = line.substring('a=fmtp:$opusPt'.length).trim();
      params = _setFmtp(params,
          {'maxaveragebitrate': '32000', 'useinbandfec': '1'});
      out.add(_restoreEol(raw, 'a=fmtp:$opusPt $params'));
      fmtpDone = true;
      continue;
    }
    out.add(raw);
  }
  if (!fmtpDone) {
    // No fmtp for the Opus payload: add one right after its rtpmap.
    final withFmtp = <String>[];
    for (final raw in out) {
      withFmtp.add(raw);
      if (raw.trim().startsWith('a=rtpmap:$opusPt')) {
        withFmtp.add(_restoreEol(raw,
            'a=fmtp:$opusPt maxaveragebitrate=32000;useinbandfec=1'));
      }
    }
    return withFmtp.join('\n');
  }
  return out.join('\n');
}

String _setFmtp(String params, Map<String, String> set) {
  final kept = <String>[];
  final keys = set.keys.map((k) => k.toLowerCase()).toSet();
  for (final p in params.split(';')) {
    final t = p.trim();
    if (t.isEmpty) continue;
    final k = t.split('=').first.trim().toLowerCase();
    if (!keys.contains(k)) kept.add(t);
  }
  for (final e in set.entries) {
    kept.add('${e.key}=${e.value}');
  }
  return kept.join(';');
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
