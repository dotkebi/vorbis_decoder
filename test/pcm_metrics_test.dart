import 'dart:typed_data';

import 'package:test/test.dart';

import '../tool/src/pcm_metrics.dart';

void main() {
  test('identical PCM has zero error', () {
    final pcm = Float32List.fromList([0, -1, 0.25, 1]);

    final result = comparePcm(pcm, pcm, channels: 2);

    expect(result.sampleCount, 4);
    expect(result.rmsError, 0);
    expect(result.maxAbsoluteError, 0);
    expect(result.maxErrorSampleIndex, -1);
    expect(result.channelRmsErrors, [0, 0]);
    expect(result.channelMaxAbsoluteErrors, [0, 0]);
  });

  test('reports overall and per-channel RMS and max errors', () {
    final reference = Float32List(4);
    final actual = Float32List.fromList([1, 0, -1, 0]);

    final result = comparePcm(reference, actual, channels: 2);

    expect(result.rmsError, closeTo(0.7071067811865476, 1e-12));
    expect(result.maxAbsoluteError, 1);
    expect(result.maxErrorSampleIndex, 0);
    expect(result.channelRmsErrors[0], 1);
    expect(result.channelRmsErrors[1], 0);
    expect(result.channelMaxAbsoluteErrors, [1, 0]);
  });

  test('empty PCM is a valid zero-error comparison', () {
    final result = comparePcm(Float32List(0), Float32List(0), channels: 1);

    expect(result.rmsError, 0);
    expect(result.maxAbsoluteError, 0);
    expect(result.channelRmsErrors, [0]);
  });

  test('f32le loader is explicitly little-endian', () {
    final bytes = ByteData(3 * Float32List.bytesPerElement)
      ..setFloat32(0, -0.5, Endian.little)
      ..setFloat32(4, 0.25, Endian.little)
      ..setFloat32(8, 1, Endian.little);

    final decoded = decodeF32le(bytes.buffer.asUint8List());

    expect(decoded, [-0.5, 0.25, 1]);
  });

  test('rejects length, interleave, and finite-value violations', () {
    expect(
      () => comparePcm(Float32List(1), Float32List(2), channels: 1),
      throwsArgumentError,
    );
    expect(
      () => comparePcm(Float32List(3), Float32List(3), channels: 2),
      throwsArgumentError,
    );
    expect(
      () => comparePcm(
        Float32List(1),
        Float32List.fromList([double.nan]),
        channels: 1,
      ),
      throwsStateError,
    );
    expect(() => decodeF32le(Uint8List(3)), throwsFormatException);
  });
}
