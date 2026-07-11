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
    test('decode $name matches ffmpeg Float32 reference', () {
      final channels = fixture['channels']! as int;
      final frames = fixture['decodedFrames']! as int;
      final decoded =
          decodeOgg(File(fixture['oggFile']! as String).readAsBytesSync());
      final reference = decodeF32le(
          File(fixture['referenceFile']! as String).readAsBytesSync());
      final limits = fixture['dartDecoderLimits']! as Map<String, Object?>;
      final rmsLimit = (limits['rmsError']! as num).toDouble();
      final maxLimit = (limits['maxAbsoluteError']! as num).toDouble();

      expect(decoded.channels, channels);
      expect(decoded.sampleRate, fixture['sampleRate']);
      expect(decoded.frames, frames);
      expect(decoded.pcm.length, frames * channels);
      expect(decoded.pcm.every((sample) => sample.isFinite), isTrue);

      final metrics = comparePcm(reference, decoded.pcm, channels: channels);
      expect(metrics.rmsError, lessThanOrEqualTo(rmsLimit));
      expect(metrics.maxAbsoluteError, lessThanOrEqualTo(maxLimit));
      for (final channelRms in metrics.channelRmsErrors) {
        expect(channelRms, lessThanOrEqualTo(rmsLimit));
      }

      if (frames > 0) {
        final edgeFrames = frames < 256 ? frames : 256;
        _expectEdge(reference, decoded.pcm, channels, 0, edgeFrames, rmsLimit,
            maxLimit);
        _expectEdge(reference, decoded.pcm, channels, frames - edgeFrames,
            edgeFrames, rmsLimit, maxLimit);
      }
    });
  }
}

void _expectEdge(
  Float32List reference,
  Float32List actual,
  int channels,
  int startFrame,
  int frameCount,
  double rmsLimit,
  double maxLimit,
) {
  final start = startFrame * channels;
  final end = start + frameCount * channels;
  final metrics = comparePcm(
    Float32List.sublistView(reference, start, end),
    Float32List.sublistView(actual, start, end),
    channels: channels,
  );
  expect(metrics.rmsError, lessThanOrEqualTo(rmsLimit));
  expect(metrics.maxAbsoluteError, lessThanOrEqualTo(maxLimit));
}
