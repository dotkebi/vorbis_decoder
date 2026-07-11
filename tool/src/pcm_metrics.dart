import 'dart:math' as math;
import 'dart:typed_data';

/// Error measurements for two equally sized, interleaved PCM buffers.
final class PcmComparison {
  const PcmComparison({
    required this.sampleCount,
    required this.rmsError,
    required this.maxAbsoluteError,
    required this.maxErrorSampleIndex,
    required this.channelRmsErrors,
    required this.channelMaxAbsoluteErrors,
  });

  final int sampleCount;
  final double rmsError;
  final double maxAbsoluteError;
  final int maxErrorSampleIndex;
  final List<double> channelRmsErrors;
  final List<double> channelMaxAbsoluteErrors;

  Map<String, Object> toJson() => {
        'sampleCount': sampleCount,
        'rmsError': rmsError,
        'maxAbsoluteError': maxAbsoluteError,
        'maxErrorSampleIndex': maxErrorSampleIndex,
        'channelRmsErrors': channelRmsErrors,
        'channelMaxAbsoluteErrors': channelMaxAbsoluteErrors,
      };
}

/// Compares two PCM buffers at zero lag.
///
/// A length mismatch is an error rather than something this helper aligns or
/// trims. Vorbis end trimming is part of decoder correctness.
PcmComparison comparePcm(
  Float32List reference,
  Float32List actual, {
  required int channels,
}) {
  if (channels <= 0) {
    throw ArgumentError.value(channels, 'channels', 'must be positive');
  }
  if (reference.length != actual.length) {
    throw ArgumentError(
      'PCM lengths differ: reference=${reference.length}, '
      'actual=${actual.length}',
    );
  }
  if (reference.length % channels != 0) {
    throw ArgumentError(
      'PCM sample count ${reference.length} is not divisible by $channels',
    );
  }

  final channelSquaredErrors = List<double>.filled(channels, 0);
  final channelMaxErrors = List<double>.filled(channels, 0);
  var totalSquaredError = 0.0;
  var maxError = 0.0;
  var maxErrorIndex = -1;

  for (var index = 0; index < reference.length; index++) {
    final expected = reference[index];
    final observed = actual[index];
    if (!expected.isFinite || !observed.isFinite) {
      throw StateError('non-finite PCM sample at index $index');
    }

    final difference = observed - expected;
    final absoluteError = difference.abs();
    final squaredError = difference * difference;
    final channel = index % channels;

    totalSquaredError += squaredError;
    channelSquaredErrors[channel] += squaredError;
    if (absoluteError > channelMaxErrors[channel]) {
      channelMaxErrors[channel] = absoluteError;
    }
    if (absoluteError > maxError) {
      maxError = absoluteError;
      maxErrorIndex = index;
    }
  }

  final frames = reference.length ~/ channels;
  final channelRmsErrors = List<double>.generate(
    channels,
    (channel) =>
        frames == 0 ? 0 : math.sqrt(channelSquaredErrors[channel] / frames),
    growable: false,
  );

  return PcmComparison(
    sampleCount: reference.length,
    rmsError:
        reference.isEmpty ? 0 : math.sqrt(totalSquaredError / reference.length),
    maxAbsoluteError: maxError,
    maxErrorSampleIndex: maxErrorIndex,
    channelRmsErrors: channelRmsErrors,
    channelMaxAbsoluteErrors: List<double>.unmodifiable(channelMaxErrors),
  );
}

/// Decodes headerless IEEE-754 little-endian float32 PCM bytes.
Float32List decodeF32le(Uint8List bytes) {
  if (bytes.lengthInBytes % Float32List.bytesPerElement != 0) {
    throw const FormatException('f32le byte length must be divisible by 4');
  }

  final data = ByteData.sublistView(bytes);
  final samples = Float32List(
    bytes.lengthInBytes ~/ Float32List.bytesPerElement,
  );
  for (var index = 0; index < samples.length; index++) {
    samples[index] = data.getFloat32(
      index * Float32List.bytesPerElement,
      Endian.little,
    );
  }
  return samples;
}
