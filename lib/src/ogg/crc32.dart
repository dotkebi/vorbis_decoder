import 'dart:typed_data';

final Uint32List _table = _makeTable();

int oggCrc32(Uint8List bytes, {int crcOffset = -1}) {
  var crc = 0;
  for (var i = 0; i < bytes.length; i++) {
    final byte = i >= crcOffset && i < crcOffset + 4 ? 0 : bytes[i];
    crc = ((crc << 8) ^ _table[((crc >> 24) & 0xff) ^ byte]) & 0xffffffff;
  }
  return crc;
}

Uint32List _makeTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var value = i << 24;
    for (var bit = 0; bit < 8; bit++) {
      value = ((value & 0x80000000) != 0)
          ? ((value << 1) ^ 0x04c11db7) & 0xffffffff
          : (value << 1) & 0xffffffff;
    }
    table[i] = value;
  }
  return table;
}
