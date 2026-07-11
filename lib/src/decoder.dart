import 'dart:typed_data';

import 'ogg/packet_reader.dart';
import 'vorbis/core.dart';

/// A malformed, unsupported, or unsafe Ogg Vorbis stream.
final class VorbisDecoderException implements Exception {
  const VorbisDecoderException(this.message, {this.offset});

  final String message;
  final int? offset;

  @override
  String toString() => offset == null
      ? 'VorbisDecoderException: $message'
      : 'VorbisDecoderException at byte $offset: $message';
}

/// Stream properties that can be obtained without audio synthesis.
final class VorbisInfo {
  const VorbisInfo({
    required this.channels,
    required this.sampleRate,
    required this.frames,
  });

  final int channels;
  final int sampleRate;
  final int frames;

  int get totalSamples => _checkedProduct(frames, channels, 'PCM sample count');
}

/// Fully decoded interleaved IEEE-754 PCM.
final class VorbisDecoded extends VorbisInfo {
  const VorbisDecoded({
    required super.channels,
    required super.sampleRate,
    required super.frames,
    required this.pcm,
  });

  final Float32List pcm;
}

/// Parses the Ogg pages and Vorbis identification header.
VorbisInfo probeOgg(Uint8List bytes) {
  try {
    return _probeOgg(bytes);
  } on VorbisDecoderException {
    rethrow;
  } on RangeError catch (error) {
    throw VorbisDecoderException('invalid index or declared size: $error');
  } on StateError catch (error) {
    throw VorbisDecoderException('invalid decoder state: $error');
  }
}

VorbisInfo _probeOgg(Uint8List bytes) {
  final stream = OggPacketReader(bytes).readVorbisStream();
  final packet = stream.packets.first.data;
  if (packet.length < 30 ||
      packet[0] != 1 ||
      !_matches(packet, 1, const [0x76, 0x6f, 0x72, 0x62, 0x69, 0x73])) {
    throw const VorbisDecoderException('invalid Vorbis identification header');
  }
  final view = ByteData.sublistView(packet);
  final version = view.getUint32(7, Endian.little);
  final channels = packet[11];
  final sampleRate = view.getUint32(12, Endian.little);
  final blockSizes = packet[28];
  final block0 = blockSizes & 15;
  final block1 = blockSizes >> 4;
  if (version != 0) {
    throw VorbisDecoderException('unsupported Vorbis version $version');
  }
  if (channels == 0 || channels > 255) {
    throw VorbisDecoderException('invalid channel count $channels');
  }
  if (sampleRate == 0) {
    throw const VorbisDecoderException('invalid sample rate 0');
  }
  if (block0 < 6 || block1 < block0 || block1 > 13) {
    throw const VorbisDecoderException('invalid Vorbis block sizes');
  }
  if ((packet[29] & 1) == 0) {
    throw const VorbisDecoderException('identification framing bit is not set');
  }
  if (stream.packets.length < 4) {
    throw const VorbisDecoderException('missing mandatory Vorbis packets');
  }
  _validateHeader(stream.packets[1].data, 3, 'comment');
  _validateHeader(stream.packets[2].data, 5, 'setup');
  final frames = stream.finalGranule;
  if (frames < 0) {
    throw const VorbisDecoderException('missing final granule position');
  }
  _checkedProduct(frames, channels, 'PCM sample count');
  return VorbisInfo(channels: channels, sampleRate: sampleRate, frames: frames);
}

/// Decodes an Ogg Vorbis stream to interleaved float PCM.
VorbisDecoded decodeOgg(Uint8List bytes) {
  try {
    final stream = OggPacketReader(bytes).readVorbisStream();
    // Run the strict public header validation before setup parsing/synthesis.
    final info = _probeOgg(bytes);
    final core = VorbisCore(stream);
    final pcm = core.decode();
    if (pcm.length != info.totalSamples) {
      throw const VorbisDecoderException('decoded PCM length mismatch');
    }
    return VorbisDecoded(
      channels: info.channels,
      sampleRate: info.sampleRate,
      frames: info.frames,
      pcm: pcm,
    );
  } on VorbisDecoderException {
    rethrow;
  } on RangeError catch (error) {
    throw VorbisDecoderException('invalid index or declared size: $error');
  } on StateError catch (error) {
    throw VorbisDecoderException('invalid decoder state: $error');
  }
}

/// Converts float PCM to signed 16-bit PCM.
///
/// Finite inputs are clamped to [-1, 1]. Values are rounded to the nearest
/// integer, with halves away from zero. -1 maps to -32768 and +1 to 32767.
/// NaN maps to zero; infinities are clamped to the corresponding endpoint.
Int16List float32ToInt16(Float32List pcm) {
  final result = Int16List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    final value = pcm[i];
    if (value.isNaN) {
      result[i] = 0;
    } else if (value <= -1) {
      result[i] = -32768;
    } else if (value >= 1) {
      result[i] = 32767;
    } else {
      result[i] = (value * (value < 0 ? 32768 : 32767)).round();
    }
  }
  return result;
}

void _validateHeader(Uint8List packet, int type, String name) {
  if (packet.length < 7 ||
      packet[0] != type ||
      !_matches(packet, 1, const [0x76, 0x6f, 0x72, 0x62, 0x69, 0x73])) {
    throw VorbisDecoderException('invalid Vorbis $name header');
  }
}

bool _matches(Uint8List bytes, int offset, List<int> expected) {
  if (offset + expected.length > bytes.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (bytes[offset + i] != expected[i]) return false;
  }
  return true;
}

int _checkedProduct(int a, int b, String label) {
  const maximumSamples = 64 * 1024 * 1024;
  if (a < 0 || b < 0) {
    throw VorbisDecoderException('$label overflow');
  }
  if (b != 0 && a > maximumSamples ~/ b) {
    throw VorbisDecoderException('$label exceeds safe allocation limit');
  }
  return a * b;
}
