import 'dart:typed_data';

import '../decoder.dart';

final class BitReader {
  BitReader(this.bytes);

  final Uint8List bytes;
  int _bit = 0;

  int get bitsRead => _bit;
  int get bitsRemaining => bytes.length * 8 - _bit;

  bool readBool() => read(1) != 0;

  int read(int count) {
    if (count < 0 || count > 53) {
      throw const VorbisDecoderException('invalid bit read width');
    }
    if (_bit + count > bytes.length * 8) {
      throw const VorbisDecoderException('truncated Vorbis packet');
    }
    var value = 0;
    for (var shift = 0; shift < count; shift++) {
      value |= ((bytes[_bit >> 3] >> (_bit & 7)) & 1) << shift;
      _bit++;
    }
    return value;
  }
}

int ilog(int value) {
  var bits = 0;
  while (value > 0) {
    bits++;
    value >>= 1;
  }
  return bits;
}
