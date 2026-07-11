import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync())
          as Map<String, Object?>;
  final fixtures =
      (manifest['fixtures']! as List<Object?>).cast<Map<String, Object?>>();
  final policy = manifest['thresholdPolicy']! as Map<String, Object?>;

  test('manifest covers the required Phase 0 matrix', () {
    expect(manifest['schemaVersion'], 1);
    expect(fixtures, hasLength(11));
    expect(
      fixtures.map((fixture) => fixture['sampleRate']).toSet(),
      containsAll(<int>{8000, 22050, 44100, 48000}),
    );
    expect(
      fixtures.map((fixture) => fixture['channels']).toSet(),
      containsAll(<int>{1, 2}),
    );

    final categories = fixtures
        .expand((fixture) => (fixture['categories']! as List<Object?>).cast())
        .toSet();
    expect(
      categories,
      containsAll(<String>{
        'tone',
        'white_noise',
        'music',
        'low_bitrate',
        'high_bitrate',
        'tiny',
        'long',
        'transient',
        'silence',
      }),
    );
  });

  test('edge fixtures describe both one-packet and non-empty minima', () {
    final onePacket = _fixtureNamed(fixtures, 'one_audio_packet_zero');
    expect(onePacket['audioPackets'], 1);
    expect(onePacket['decodedFrames'], 0);

    final tiny = _fixtureNamed(fixtures, 'tiny_tone_mono_8000');
    expect(tiny['audioPackets'], 2);
    expect(tiny['decodedFrames'], 8);

    final long = _fixtureNamed(fixtures, 'long_stereo_48000');
    expect(long['decodedFrames'], 480000);
    final music = _fixtureNamed(fixtures, 'music_stereo_44100');
    expect(music['decodedFrames'], 132300);
  });

  test('committed reference corpus stays below 8 MiB', () {
    final totalBytes = fixtures.fold<int>(
      0,
      (sum, fixture) => sum + (fixture['referenceBytes']! as int),
    );
    expect(totalBytes, lessThan(8 * 1024 * 1024));
  });

  for (final fixture in fixtures) {
    final name = fixture['name']! as String;
    test('$name artifacts and calibration are intact', () async {
      final channels = fixture['channels']! as int;
      final decodedFrames = fixture['decodedFrames']! as int;
      final oggFile = File(fixture['oggFile']! as String);
      final referenceFile = File(fixture['referenceFile']! as String);
      final source = fixture['source']! as Map<String, Object?>;

      expect(oggFile.existsSync(), isTrue);
      expect(referenceFile.existsSync(), isTrue);
      expect(await oggFile.length(), fixture['oggBytes']);
      expect(await referenceFile.length(), fixture['referenceBytes']);
      expect(await _sha256(oggFile), fixture['oggSha256']);
      expect(await _sha256(referenceFile), fixture['referenceSha256']);
      expect(await referenceFile.length(), decodedFrames * channels * 4);
      expect(fixture['sourceFrames'], decodedFrames);
      if (source['file'] case final String sourcePath) {
        final sourceFile = File(sourcePath);
        expect(sourceFile.existsSync(), isTrue);
        expect(await _sha256(sourceFile), source['sha256']);
      }

      final capture = await oggFile
          .openRead(0, 4)
          .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
      expect(utf8.decode(capture), 'OggS');

      final baseline = fixture['referenceBaseline']! as Map<String, Object?>;
      final rms = (baseline['rmsError']! as num).toDouble();
      final maxError = (baseline['maxAbsoluteError']! as num).toDouble();
      expect(
        rms,
        lessThanOrEqualTo((policy['referenceRmsCeiling']! as num).toDouble()),
      );
      expect(
        maxError,
        lessThanOrEqualTo((policy['referenceMaxCeiling']! as num).toDouble()),
      );
      expect(
        baseline['channelRmsErrors'],
        isA<List<Object?>>().having(
          (values) => values.length,
          'length',
          channels,
        ),
      );
      expect(
        baseline['channelMaxAbsoluteErrors'],
        isA<List<Object?>>().having(
          (values) => values.length,
          'length',
          channels,
        ),
      );

      final limits = fixture['dartDecoderLimits']! as Map<String, Object?>;
      expect(
        (limits['rmsError']! as num).toDouble(),
        greaterThanOrEqualTo(
          math.max(
            (policy['minimumDartRmsLimit']! as num).toDouble(),
            rms * (policy['dartLimitMultiplier']! as num).toDouble(),
          ),
        ),
      );
      expect(
        (limits['maxAbsoluteError']! as num).toDouble(),
        greaterThanOrEqualTo(
          math.max(
            (policy['minimumDartMaxLimit']! as num).toDouble(),
            maxError * (policy['dartLimitMultiplier']! as num).toDouble(),
          ),
        ),
      );
    });
  }

  test('the package library remains free of dart:io', () {
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in dartFiles) {
      expect(file.readAsStringSync(), isNot(contains("'dart:io'")));
      expect(file.readAsStringSync(), isNot(contains('"dart:io"')));
    }
  });
}

Map<String, Object?> _fixtureNamed(
  List<Map<String, Object?>> fixtures,
  String name,
) =>
    fixtures.singleWhere((fixture) => fixture['name'] == name);

Future<String> _sha256(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
