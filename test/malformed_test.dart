import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vorbis_decoder/src/ogg/crc32.dart';
import 'package:vorbis_decoder/vorbis_decoder.dart';

void main() {
  final valid =
      File('test/fixtures/ogg/tiny_tone_mono_8000.ogg').readAsBytesSync();

  test('container structural failures return decoder exceptions', () {
    final cases = <Uint8List>[
      Uint8List(0),
      Uint8List.fromList([1, 2, 3, 4]),
      Uint8List.fromList(valid.sublist(0, 20)),
      Uint8List.fromList(valid.sublist(0, valid.length - 1)),
      _mutate(valid, 0, 0),
      _mutate(valid, 4, 1),
      _mutate(valid, 100, valid[100] ^ 1),
      _mutate(valid, 26, 255),
      _withPageMutation(valid, 0, (bytes, page) {
        bytes[page + 5] |= 1;
      }),
      _withPageMutation(valid, 1, (bytes, page) {
        bytes[page + 14] ^= 1;
      }),
      _withPageMutation(valid, 2, (bytes, page) {
        bytes[page + 5] &= ~4;
      }),
      _withPageMutation(valid, 2, (bytes, page) {
        final body = page + 27 + bytes[page + 26];
        bytes[body] |= 1;
      }),
    ];
    for (var i = 0; i < cases.length; i++) {
      expect(() => decodeOgg(cases[i]), throwsA(isA<VorbisDecoderException>()),
          reason: 'structural case $i');
    }
  });

  test('identification and setup damage return decoder exceptions', () {
    final first = _pages(valid).first;
    final packet = first + 27 + valid[first + 26];
    final cases = <Uint8List>[
      _withPageMutation(valid, 0, (bytes, _) => bytes[packet] = 7),
      _withPageMutation(valid, 0, (bytes, _) => bytes[packet + 7] = 1),
      _withPageMutation(valid, 0, (bytes, _) => bytes[packet + 11] = 0),
      _withPageMutation(valid, 0, (bytes, _) {
        for (var i = 12; i < 16; i++) {
          bytes[packet + i] = 0;
        }
      }),
      _withPageMutation(valid, 0, (bytes, _) => bytes[packet + 28] = 0x55),
      _corruptSignaturePacket(
          valid, const [5, 0x76, 0x6f, 0x72, 0x62, 0x69, 0x73]),
    ];
    for (final bytes in cases) {
      expect(() => decodeOgg(bytes), throwsA(isA<VorbisDecoderException>()));
    }
  });

  test('extreme granules and allocation requests are rejected', () {
    final huge = _withPageMutation(valid, 1, (bytes, page) {
      for (var i = 6; i < 14; i++) {
        bytes[page + i] = 0xff;
      }
      bytes[page + 13] = 0x7f;
    });
    expect(() => probeOgg(huge), throwsA(isA<VorbisDecoderException>()));

    final multiPage = File('test/fixtures/ogg/dual_tone_stereo_44100_high.ogg')
        .readAsBytesSync();
    final backwards = _withPageMutation(multiPage, 3, (bytes, page) {
      ByteData.sublistView(bytes).setUint64(page + 6, 100, Endian.little);
    });
    expect(() => probeOgg(backwards), throwsA(isA<VorbisDecoderException>()));
  });

  test('zero-frame stream is a valid empty decode', () {
    final bytes =
        File('test/fixtures/ogg/one_audio_packet_zero.ogg').readAsBytesSync();
    final decoded = decodeOgg(bytes);
    expect(decoded.frames, 0);
    expect(decoded.pcm, isEmpty);
  });

  test('deterministic byte mutation never hangs or leaks RangeError', () {
    const seed = 0x564f5242;
    final random = math.Random(seed);
    for (var i = 0; i < 128; i++) {
      final bytes = Uint8List.fromList(valid);
      final offset = random.nextInt(bytes.length);
      bytes[offset] ^= 1 << random.nextInt(8);
      expect(
        () => decodeOgg(bytes),
        throwsA(isA<VorbisDecoderException>()),
        reason: 'seed=$seed mutation=$i offset=$offset',
      );
    }
  });
}

Uint8List _mutate(Uint8List source, int offset, int value) =>
    Uint8List.fromList(source)..[offset] = value;

List<int> _pages(Uint8List bytes) {
  final pages = <int>[];
  var offset = 0;
  while (offset < bytes.length) {
    pages.add(offset);
    final segments = bytes[offset + 26];
    var body = 0;
    for (var i = 0; i < segments; i++) {
      body += bytes[offset + 27 + i];
    }
    offset += 27 + segments + body;
  }
  return pages;
}

Uint8List _withPageMutation(
  Uint8List source,
  int pageIndex,
  void Function(Uint8List bytes, int pageOffset) mutate,
) {
  final bytes = Uint8List.fromList(source);
  final page = _pages(bytes)[pageIndex];
  mutate(bytes, page);
  _repairCrc(bytes, page);
  return bytes;
}

Uint8List _corruptSignaturePacket(Uint8List source, List<int> signature) {
  final bytes = Uint8List.fromList(source);
  var found = -1;
  for (var i = 0; i <= bytes.length - signature.length; i++) {
    var matches = true;
    for (var j = 0; j < signature.length; j++) {
      if (bytes[i + j] != signature[j]) matches = false;
    }
    if (matches) {
      found = i;
      break;
    }
  }
  if (found < 0) throw StateError('signature not found');
  bytes[found + signature.length] ^= 1;
  final pages = _pages(bytes);
  final page = pages.lastWhere((offset) => offset <= found);
  _repairCrc(bytes, page);
  return bytes;
}

void _repairCrc(Uint8List bytes, int page) {
  final segments = bytes[page + 26];
  var body = 0;
  for (var i = 0; i < segments; i++) {
    body += bytes[page + 27 + i];
  }
  final length = 27 + segments + body;
  final view = Uint8List.sublistView(bytes, page, page + length);
  final crc = oggCrc32(view, crcOffset: 22);
  ByteData.sublistView(bytes).setUint32(page + 22, crc, Endian.little);
}
