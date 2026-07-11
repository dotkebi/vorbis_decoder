import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vorbis_decoder/vorbis_decoder.dart';

import '../tool/src/pcm_metrics.dart';

void main() {
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync())
          as Map<String, Object?>;
  final fixtures =
      (manifest['fixtures']! as List<Object?>).cast<Map<String, Object?>>();

  for (final fixture in fixtures) {
    final name = fixture['name']! as String;
    test('probe $name reports exact stream properties', () {
      final bytes = File(fixture['oggFile']! as String).readAsBytesSync();
      final info = probeOgg(bytes);
      expect(info.channels, fixture['channels']);
      expect(info.sampleRate, fixture['sampleRate']);
      expect(info.frames, fixture['decodedFrames']);
      expect(info.totalSamples,
          (fixture['decodedFrames']! as int) * (fixture['channels']! as int));
    });
  }

  test('Float32 to Int16 conversion has explicit boundary behavior', () {
    final output = float32ToInt16(Float32List.fromList([
      double.negativeInfinity,
      -1,
      -0.5,
      -0.0,
      double.nan,
      0.5,
      1,
      double.infinity,
    ]));
    expect(output, [-32768, -32768, -16384, 0, 0, 16384, 32767, 32767]);
  });

  test('decodes the minimum non-empty fixture', () {
    final fixture = fixtures[1];
    final decoded =
        decodeOgg(File(fixture['oggFile']! as String).readAsBytesSync());
    expect(decoded.frames, 8);
    expect(decoded.pcm, hasLength(8));
    expect(decoded.pcm.every((sample) => sample.isFinite), isTrue);
    final reference = decodeF32le(
        File(fixture['referenceFile']! as String).readAsBytesSync());
    final metrics = comparePcm(reference, decoded.pcm, channels: 1);
    expect(metrics.rmsError,
        lessThanOrEqualTo((fixture['dartDecoderLimits']! as Map)['rmsError']));
    expect(
        metrics.maxAbsoluteError,
        lessThanOrEqualTo(
            (fixture['dartDecoderLimits']! as Map)['maxAbsoluteError']));
  });

  test('empty, garbage, truncated, CRC-corrupt, and missing EOS fail', () {
    final valid = File(fixtures[1]['oggFile']! as String).readAsBytesSync();
    final crcCorrupt = Uint8List.fromList(valid)..[100] ^= 1;
    final withoutEos = Uint8List.sublistView(valid, 0, valid.length - 1);
    for (final bytes in <Uint8List>[
      Uint8List(0),
      Uint8List.fromList([1, 2, 3, 4]),
      Uint8List.fromList(valid.sublist(0, 20)),
      crcCorrupt,
      withoutEos,
    ]) {
      expect(() => probeOgg(bytes), throwsA(isA<VorbisDecoderException>()));
    }
  });
}
