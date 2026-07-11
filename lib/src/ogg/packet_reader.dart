import 'dart:typed_data';

import '../decoder.dart';
import 'crc32.dart';

final class OggPacket {
  const OggPacket(this.data, this.granule, this.endOfStream);

  final Uint8List data;
  final int? granule;
  final bool endOfStream;
}

final class OggStream {
  const OggStream(this.packets, this.finalGranule);

  final List<OggPacket> packets;
  final int finalGranule;
}

final class OggPacketReader {
  OggPacketReader(this.bytes);

  static const _maxPacketBytes = 64 * 1024 * 1024;
  final Uint8List bytes;

  OggStream readVorbisStream() {
    if (bytes.isEmpty) {
      throw const VorbisDecoderException('empty input');
    }
    var offset = 0;
    int? serial;
    var expectedSequence = 0;
    var sawBos = false;
    var sawEos = false;
    var finalGranule = -1;
    var previousGranule = -1;
    final partial = BytesBuilder(copy: false);
    final packets = <OggPacket>[];

    while (offset < bytes.length) {
      if (bytes.length - offset < 27) {
        throw VorbisDecoderException('truncated Ogg page header',
            offset: offset);
      }
      if (bytes[offset] != 0x4f ||
          bytes[offset + 1] != 0x67 ||
          bytes[offset + 2] != 0x67 ||
          bytes[offset + 3] != 0x53) {
        throw VorbisDecoderException('invalid Ogg capture pattern',
            offset: offset);
      }
      if (bytes[offset + 4] != 0) {
        throw VorbisDecoderException('unsupported Ogg version',
            offset: offset + 4);
      }
      final flags = bytes[offset + 5];
      if ((flags & ~7) != 0) {
        throw VorbisDecoderException('invalid Ogg header flags',
            offset: offset + 5);
      }
      final pageGranule = _granule(offset + 6);
      final pageSerial = _uint32(offset + 14);
      final sequence = _uint32(offset + 18);
      final storedCrc = _uint32(offset + 22);
      final segmentCount = bytes[offset + 26];
      final headerLength = 27 + segmentCount;
      if (bytes.length - offset < headerLength) {
        throw VorbisDecoderException('truncated Ogg lacing table',
            offset: offset);
      }
      var bodyLength = 0;
      for (var i = 0; i < segmentCount; i++) {
        bodyLength += bytes[offset + 27 + i];
      }
      final pageLength = headerLength + bodyLength;
      if (pageLength > bytes.length - offset) {
        throw VorbisDecoderException('truncated Ogg page body', offset: offset);
      }
      final page = Uint8List.sublistView(bytes, offset, offset + pageLength);
      if (oggCrc32(page, crcOffset: 22) != storedCrc) {
        throw VorbisDecoderException('Ogg CRC mismatch', offset: offset);
      }
      if (serial == null) {
        serial = pageSerial;
        if ((flags & 2) == 0) {
          throw VorbisDecoderException('first page is not BOS', offset: offset);
        }
      } else if (serial != pageSerial) {
        throw VorbisDecoderException('logical stream serial changed',
            offset: offset);
      }
      if (sequence != expectedSequence) {
        throw VorbisDecoderException('Ogg page sequence mismatch',
            offset: offset);
      }
      expectedSequence++;
      if (sawEos) {
        throw VorbisDecoderException('data follows EOS page', offset: offset);
      }
      if ((flags & 2) != 0) {
        if (sawBos || sequence != 0) {
          throw VorbisDecoderException('unexpected BOS page', offset: offset);
        }
        sawBos = true;
      }
      final continued = (flags & 1) != 0;
      if (continued != (partial.length != 0)) {
        throw VorbisDecoderException('continued packet mismatch',
            offset: offset);
      }
      if (pageGranule >= 0) {
        if (previousGranule >= 0 && pageGranule < previousGranule) {
          throw VorbisDecoderException('granule position moved backwards',
              offset: offset);
        }
        previousGranule = pageGranule;
        finalGranule = pageGranule;
      }

      var bodyOffset = offset + headerLength;
      for (var i = 0; i < segmentCount; i++) {
        final lace = bytes[offset + 27 + i];
        if (partial.length + lace > _maxPacketBytes) {
          throw VorbisDecoderException('Ogg packet exceeds safety limit',
              offset: offset);
        }
        partial
            .add(Uint8List.sublistView(bytes, bodyOffset, bodyOffset + lace));
        bodyOffset += lace;
        if (lace < 255) {
          final isLastCompleted = i == segmentCount - 1;
          packets.add(OggPacket(
            partial.takeBytes(),
            isLastCompleted && pageGranule >= 0 ? pageGranule : null,
            isLastCompleted && (flags & 4) != 0,
          ));
        }
      }
      sawEos = (flags & 4) != 0;
      if (sawEos && partial.length != 0) {
        throw VorbisDecoderException('EOS ends with a truncated packet',
            offset: offset);
      }
      offset += pageLength;
    }
    if (!sawEos) {
      throw const VorbisDecoderException('missing Ogg EOS page');
    }
    if (packets.isEmpty) {
      throw const VorbisDecoderException('Ogg stream contains no packets');
    }
    return OggStream(List.unmodifiable(packets), finalGranule);
  }

  int _uint32(int offset) =>
      ByteData.sublistView(bytes).getUint32(offset, Endian.little);

  int _granule(int offset) {
    final low = _uint32(offset);
    final high = _uint32(offset + 4);
    if (low == 0xffffffff && high == 0xffffffff) return -1;
    // JavaScript integers are exact through 2^53-1. Larger granules cannot
    // safely describe an in-memory output and are rejected before combining.
    if (high > 0x001fffff) {
      throw VorbisDecoderException('granule exceeds safe integer range',
          offset: offset);
    }
    return high * 0x100000000 + low;
  }
}
