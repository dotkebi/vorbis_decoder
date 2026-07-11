import 'dart:convert';
import 'dart:io';

import 'package:vorbis_decoder/vorbis_decoder.dart';

import 'src/pcm_metrics.dart';

void main() {
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync())
          as Map<String, Object?>;
  final fixtures =
      (manifest['fixtures']! as List<Object?>).cast<Map<String, Object?>>();
  stdout.writeln('fixture,frames,channels,sample_rate,rms,max_abs,status');
  for (final fixture in fixtures) {
    final decoded =
        decodeOgg(File(fixture['oggFile']! as String).readAsBytesSync());
    final reference = decodeF32le(
        File(fixture['referenceFile']! as String).readAsBytesSync());
    final metrics =
        comparePcm(reference, decoded.pcm, channels: decoded.channels);
    final limits = fixture['dartDecoderLimits']! as Map<String, Object?>;
    final passed = metrics.rmsError <= (limits['rmsError']! as num) &&
        metrics.maxAbsoluteError <= (limits['maxAbsoluteError']! as num);
    stdout.writeln('${fixture['name']},${decoded.frames},${decoded.channels},'
        '${decoded.sampleRate},${metrics.rmsError},'
        '${metrics.maxAbsoluteError},${passed ? 'PASS' : 'FAIL'}');
  }
}
