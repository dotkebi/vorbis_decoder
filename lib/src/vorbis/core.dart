import 'dart:math' as math;
import 'dart:typed_data';

import '../decoder.dart';
import '../ogg/packet_reader.dart';
import 'bit_reader.dart';

final class VorbisCore {
  VorbisCore(OggStream stream)
      : _stream = stream,
        _id = _Identification(stream.packets[0].data) {
    _setup = _Setup(BitReader(stream.packets[2].data), _id);
  }

  final OggStream _stream;
  final _Identification _id;
  late final _Setup _setup;

  int get channels => _id.channels;
  int get sampleRate => _id.sampleRate;

  Float32List decode() {
    final targetFrames = _stream.finalGranule;
    final output = Float32List(targetFrames * channels);
    _AudioBlock? previous;
    var writtenFrames = 0;
    var audioPackets = 0;
    final pcmBuffers = <int, List<List<Float64List>>>{};
    for (var i = 3; i < _stream.packets.length; i++) {
      audioPackets++;
      final reader = BitReader(_stream.packets[i].data);
      if (reader.readBool()) {
        throw const VorbisDecoderException('invalid audio packet type bit');
      }
      final modeNumber = reader.read(ilog(_setup.modes.length - 1));
      if (modeNumber >= _setup.modes.length) {
        throw const VorbisDecoderException('invalid audio mode');
      }
      final mode = _setup.modes[modeNumber];
      var previousLong = false;
      var nextLong = false;
      if (mode.longBlock) {
        previousLong = reader.readBool();
        nextLong = reader.readBool();
      }
      final size = mode.longBlock ? _id.block1 : _id.block0;
      final buffers = pcmBuffers.putIfAbsent(
          size,
          () => List.generate(
              2, (_) => List.generate(channels, (_) => Float64List(size))));
      final pcm = mode.mapping
          .decode(reader, size, channels, output: buffers[audioPackets & 1]);
      for (var ch = 0; ch < channels; ch++) {
        _inverseMdct(pcm[ch], size);
        _window(pcm[ch], size, _id.block0, previousLong, nextLong);
      }
      final previousSize = mode.longBlock && previousLong ? size : _id.block0;
      final nextSize = mode.longBlock && nextLong ? size : _id.block0;
      final start = size ~/ 4 - previousSize ~/ 4;
      final total = size * 3 ~/ 4 + nextSize ~/ 4;
      final valid = total - nextSize ~/ 2;
      final current = _AudioBlock(pcm, size, start, valid, total);
      if (previous != null) {
        // The first packet is synthesis pre-roll. Each later packet owns the
        // overlap result from [start, valid), after adding the previous tail.
        final overlapCount = previous.total - previous.valid;
        for (var ch = 0; ch < channels; ch++) {
          for (var j = 0; j < overlapCount; j++) {
            current.pcm[ch][current.start + j] +=
                previous.pcm[ch][previous.valid + j];
          }
        }
        for (var sourceFrame = current.start;
            sourceFrame < current.valid && writtenFrames < targetFrames;
            sourceFrame++, writtenFrames++) {
          for (var ch = 0; ch < channels; ch++) {
            final value = current.pcm[ch][sourceFrame];
            if (!value.isFinite) {
              throw const VorbisDecoderException(
                  'decoder produced non-finite PCM');
            }
            output[writtenFrames * channels + ch] = value;
          }
        }
      }
      previous = current;
    }
    if (audioPackets == 0) {
      throw const VorbisDecoderException('stream contains no audio packets');
    }
    if (writtenFrames < targetFrames) {
      throw VorbisDecoderException(
          'decoded $writtenFrames frames, expected $targetFrames');
    }
    return output;
  }
}

final class _Identification {
  _Identification(Uint8List packet) {
    final data = ByteData.sublistView(packet);
    channels = packet[11];
    sampleRate = data.getUint32(12, Endian.little);
    block0 = 1 << (packet[28] & 15);
    block1 = 1 << (packet[28] >> 4);
  }
  late final int channels;
  late final int sampleRate;
  late final int block0;
  late final int block1;
}

final class _Setup {
  _Setup(BitReader bits, _Identification id) {
    if (bits.read(8) != 5 || bits.read(48) != 0x736962726f76) {
      throw const VorbisDecoderException('invalid Vorbis setup header');
    }
    books = List.generate(bits.read(8) + 1, (_) => _Codebook(bits));
    final timeCount = bits.read(6) + 1;
    for (var i = 0; i < timeCount; i++) {
      if (bits.read(16) != 0) {
        throw const VorbisDecoderException('unsupported Vorbis time transform');
      }
    }
    floors = List.generate(bits.read(6) + 1, (_) {
      final type = bits.read(16);
      if (type != 1) {
        throw VorbisDecoderException('unsupported floor type $type');
      }
      return _Floor1(bits, books);
    });
    residues = List.generate(bits.read(6) + 1, (_) {
      final type = bits.read(16);
      if (type > 2) throw VorbisDecoderException('invalid residue type $type');
      return _Residue(bits, books, type);
    });
    mappings = List.generate(bits.read(6) + 1, (_) {
      if (bits.read(16) != 0) {
        throw const VorbisDecoderException('unsupported mapping type');
      }
      return _Mapping(bits, id.channels, floors, residues);
    });
    modes = List.generate(bits.read(6) + 1, (_) {
      final longBlock = bits.readBool();
      if (bits.read(16) != 0 || bits.read(16) != 0) {
        throw const VorbisDecoderException('unsupported mode transform/window');
      }
      final mapping = bits.read(8);
      if (mapping >= mappings.length) {
        throw const VorbisDecoderException('invalid mode mapping');
      }
      return _Mode(longBlock, mappings[mapping]);
    });
    if (!bits.readBool()) {
      throw const VorbisDecoderException('setup framing bit is not set');
    }
  }

  late final List<_Codebook> books;
  late final List<_Floor1> floors;
  late final List<_Residue> residues;
  late final List<_Mapping> mappings;
  late final List<_Mode> modes;
}

final class _Codebook {
  _Codebook(BitReader bits) {
    if (bits.read(24) != 0x564342) {
      throw const VorbisDecoderException('invalid codebook sync');
    }
    dimensions = bits.read(16);
    entries = bits.read(24);
    if (dimensions < 1 || entries < 1 || entries > 1 << 20) {
      throw const VorbisDecoderException('unsafe codebook dimensions');
    }
    final lengths = Int32List(entries);
    if (bits.readBool()) {
      var length = bits.read(5) + 1;
      var entry = 0;
      while (entry < entries) {
        final count = bits.read(ilog(entries - entry));
        if (entry + count > entries) {
          throw const VorbisDecoderException('invalid ordered codebook');
        }
        for (var i = 0; i < count; i++) {
          lengths[entry++] = length;
        }
        length++;
      }
    } else {
      final sparse = bits.readBool();
      for (var i = 0; i < entries; i++) {
        if (!sparse || bits.readBool()) lengths[i] = bits.read(5) + 1;
      }
    }
    _root = _HuffmanNode();
    final first = lengths.indexWhere((length) => length > 0);
    if (first >= 0) {
      if (lengths[first] > 32) {
        throw const VorbisDecoderException('codeword too long');
      }
      _addCodeword(first, lengths[first], 0);
      final available = List<int>.filled(33, 0);
      for (var length = 1; length <= lengths[first]; length++) {
        available[length] = 1 << (32 - length);
      }
      for (var symbol = first + 1; symbol < entries; symbol++) {
        final length = lengths[symbol];
        if (length == 0) continue;
        if (length > 32) {
          throw const VorbisDecoderException('codeword too long');
        }
        var slot = length;
        while (slot > 0 && available[slot] == 0) {
          slot--;
        }
        if (slot == 0) {
          throw const VorbisDecoderException('overpopulated codebook');
        }
        final codeword = available[slot];
        available[slot] = 0;
        _addCodeword(symbol, length, codeword);
        if (slot != length) {
          for (var next = length; next > slot; next--) {
            available[next] = codeword + (1 << (32 - next));
          }
        }
      }
    }

    mapType = bits.read(4);
    if (mapType > 2) throw const VorbisDecoderException('invalid codebook map');
    if (mapType == 0) return;
    final minimum = _unpackFloat(bits.read(32));
    final delta = _unpackFloat(bits.read(32));
    final valueBits = bits.read(4) + 1;
    final sequence = bits.readBool();
    var multiplicandCount = entries * dimensions;
    if (mapType == 1) multiplicandCount = _lookup1Values(entries, dimensions);
    if (multiplicandCount > 1 << 24) {
      throw const VorbisDecoderException('unsafe codebook lookup allocation');
    }
    final multiplicands =
        List.generate(multiplicandCount, (_) => bits.read(valueBits));
    final table = Float64List(entries * dimensions);
    lookup = table;
    for (var entry = 0; entry < entries; entry++) {
      var last = 0.0;
      var divisor = 1;
      for (var dim = 0; dim < dimensions; dim++) {
        final index = mapType == 1
            ? (entry ~/ divisor) % multiplicandCount
            : entry * dimensions + dim;
        final value = multiplicands[index] * delta + minimum + last;
        table[entry * dimensions + dim] = value;
        if (sequence) last = value;
        if (mapType == 1) divisor *= multiplicandCount;
      }
    }
  }

  late final int dimensions;
  late final int entries;
  late final int mapType;
  late final _HuffmanNode _root;
  Float64List? lookup;

  void _addCodeword(int symbol, int length, int leftAlignedCodeword) {
    var node = _root;
    for (var bit = 31; bit >= 32 - length; bit--) {
      final one = ((leftAlignedCodeword >> bit) & 1) != 0;
      node =
          one ? (node.one ??= _HuffmanNode()) : (node.zero ??= _HuffmanNode());
    }
    if (node.symbol != -1) {
      throw const VorbisDecoderException('duplicate codeword');
    }
    node.symbol = symbol;
  }

  int decodeScalar(BitReader bits) {
    var node = _root;
    for (var depth = 0; depth <= 32; depth++) {
      if (node.symbol >= 0) return node.symbol;
      final next = bits.readBool() ? node.one : node.zero;
      if (next == null) {
        throw const VorbisDecoderException('invalid Huffman codeword');
      }
      node = next;
    }
    throw const VorbisDecoderException('invalid Huffman codeword');
  }

  double value(int entry, int dimension) {
    final table = lookup;
    if (table == null || entry < 0 || entry >= entries) {
      throw const VorbisDecoderException('invalid codebook lookup');
    }
    return table[entry * dimensions + dimension];
  }
}

final class _HuffmanNode {
  _HuffmanNode? zero;
  _HuffmanNode? one;
  int symbol = -1;
}

double _unpackFloat(int value) {
  final mantissa = value & 0x1fffff;
  final signed = (value & 0x80000000) != 0 ? -mantissa : mantissa;
  final exponent = ((value & 0x7fe00000) >> 21) - 788;
  return (signed * math.pow(2.0, exponent)).toDouble();
}

int _lookup1Values(int entries, int dimensions) {
  var value = math.pow(entries, 1 / dimensions).floor();
  while (math.pow(value + 1, dimensions) <= entries) {
    value++;
  }
  while (math.pow(value, dimensions) > entries) {
    value--;
  }
  return value;
}

final class _FloorData {
  _FloorData(this.used, this.y);
  bool used;
  final Int32List y;
}

final class _Floor1 {
  _Floor1(BitReader bits, this.books) {
    final partitionCount = bits.read(5);
    partitionClass = List.generate(partitionCount, (_) => bits.read(4));
    final maximumClass = partitionClass.fold(-1, math.max);
    classDimensions = Int32List(maximumClass + 1);
    classSubclasses = Int32List(maximumClass + 1);
    classMasterbook = Int32List(maximumClass + 1)
      ..fillRange(0, maximumClass + 1, -1);
    subclassBooks = List.generate(maximumClass + 1, (_) => <int>[]);
    for (var cls = 0; cls <= maximumClass; cls++) {
      classDimensions[cls] = bits.read(3) + 1;
      final subclasses = bits.read(2);
      classSubclasses[cls] = subclasses;
      if (subclasses > 0) classMasterbook[cls] = bits.read(8);
      subclassBooks[cls] =
          List.generate(1 << subclasses, (_) => bits.read(8) - 1);
    }
    multiplier = bits.read(2) + 1;
    final rangeBits = bits.read(4);
    x = <int>[0, 1 << rangeBits];
    for (final cls in partitionClass) {
      for (var i = 0; i < classDimensions[cls]; i++) {
        x.add(bits.read(rangeBits));
      }
    }
    low = Int32List(x.length);
    high = Int32List(x.length)..fillRange(0, x.length, 1);
    for (var i = 2; i < x.length; i++) {
      for (var j = 0; j < i; j++) {
        if (x[j] < x[i] && x[j] > x[low[i]]) low[i] = j;
        if (x[j] > x[i] && x[j] < x[high[i]]) high[i] = j;
      }
      if (x[low[i]] == x[high[i]]) {
        throw const VorbisDecoderException('invalid floor X coordinates');
      }
    }
  }

  final List<_Codebook> books;
  late final List<int> partitionClass;
  late final Int32List classDimensions;
  late final Int32List classSubclasses;
  late final Int32List classMasterbook;
  late final List<List<int>> subclassBooks;
  late final int multiplier;
  late final List<int> x;
  late final Int32List low;
  late final Int32List high;

  _FloorData unpack(BitReader bits) {
    if (!bits.readBool()) return _FloorData(false, Int32List(x.length));
    const ranges = [256, 128, 86, 64];
    final range = ranges[multiplier - 1];
    final yBits = ilog(range - 1);
    final y = Int32List(x.length);
    y[0] = bits.read(yBits);
    y[1] = bits.read(yBits);
    var offset = 2;
    for (final cls in partitionClass) {
      final subclasses = classSubclasses[cls];
      var selector =
          subclasses == 0 ? 0 : books[classMasterbook[cls]].decodeScalar(bits);
      for (var i = 0; i < classDimensions[cls]; i++) {
        final book = subclassBooks[cls][selector & ((1 << subclasses) - 1)];
        selector >>= subclasses;
        y[offset++] = book >= 0 ? books[book].decodeScalar(bits) : 0;
      }
    }
    return _FloorData(true, y);
  }

  void apply(_FloorData data, int size, Float64List output) {
    final y = data.y;
    final active = List.filled(x.length, false)
      ..[0] = true
      ..[1] = true;
    const ranges = [256, 128, 86, 64];
    final range = ranges[multiplier - 1];
    for (var i = 2; i < x.length; i++) {
      final predicted =
          _renderPoint(x[low[i]], y[low[i]], x[high[i]], y[high[i]], x[i]);
      final highRoom = range - predicted;
      final lowRoom = predicted;
      final room = 2 * math.min(highRoom, lowRoom);
      final value = y[i];
      if (value != 0) {
        active[i] = active[low[i]] = active[high[i]] = true;
        if (value >= room) {
          y[i] = highRoom > lowRoom
              ? value - lowRoom + predicted
              : predicted - value + highRoom - 1;
        } else {
          y[i] = (value & 1) != 0
              ? predicted - ((value + 1) >> 1)
              : predicted + (value >> 1);
        }
      } else {
        y[i] = predicted;
      }
    }
    final order = List.generate(x.length, (i) => i)
      ..sort((a, b) => x[a].compareTo(x[b]));
    var lx = 0;
    var ly = y[0] * multiplier;
    for (final index in order.skip(1)) {
      if (!active[index]) continue;
      final hx = math.min(x[index], size >> 1);
      final hy = y[index] * multiplier;
      _renderLine(lx, ly, hx, hy, output);
      lx = hx;
      ly = hy;
      if (lx >= size >> 1) break;
    }
    final gain = _inverseDb(ly);
    for (var i = lx; i < size >> 1; i++) {
      output[i] *= gain;
    }
  }
}

int _renderPoint(int x0, int y0, int x1, int y1, int x) =>
    y0 + ((y1 - y0).abs() * (x - x0) ~/ (x1 - x0)) * (y1 < y0 ? -1 : 1);

double _inverseDb(int value) => math.exp((value - 255) * 0.06296131113655594);

void _renderLine(int x0, int y0, int x1, int y1, Float64List output) {
  if (x1 <= x0) return;
  final dy = y1 - y0;
  final base = dy ~/ (x1 - x0);
  final remainder = dy.abs() - base.abs() * (x1 - x0);
  var error = 0;
  var y = y0;
  final step = dy < 0 ? base - 1 : base + 1;
  for (var x = x0; x < x1 && x < output.length ~/ 2; x++) {
    output[x] *= _inverseDb(y);
    error += remainder;
    if (error >= x1 - x0) {
      error -= x1 - x0;
      y += step;
    } else {
      y += base;
    }
  }
}

final class _Residue {
  _Residue(BitReader bits, this.books, this.type) {
    begin = bits.read(24);
    end = bits.read(24);
    partitionSize = bits.read(24) + 1;
    classifications = bits.read(6) + 1;
    classbook = bits.read(8);
    cascade = Int32List(classifications);
    for (var i = 0; i < classifications; i++) {
      final low = bits.read(3);
      cascade[i] = low | (bits.readBool() ? bits.read(5) << 3 : 0);
    }
    stageBooks = List.generate(classifications, (classification) {
      return List.generate(8, (stage) {
        if ((cascade[classification] & (1 << stage)) == 0) return -1;
        final book = bits.read(8);
        if (book >= books.length) {
          throw const VorbisDecoderException('invalid residue book');
        }
        return book;
      });
    });
    final classDimensions = books[classbook].dimensions;
    decodeMap = List.generate(books[classbook].entries, (entry) {
      var value = entry;
      final map = Int32List(classDimensions);
      var divisor = math.pow(classifications, classDimensions - 1).toInt();
      for (var i = 0; i < classDimensions; i++) {
        map[i] = value ~/ divisor;
        value -= map[i] * divisor;
        divisor ~/= classifications;
      }
      return map;
    });
  }

  final List<_Codebook> books;
  final int type;
  late final int begin;
  late final int end;
  late final int partitionSize;
  late final int classifications;
  late final int classbook;
  late final Int32List cascade;
  late final List<List<int>> stageBooks;
  late final List<Int32List> decodeMap;

  void decode(
      BitReader bits, List<bool> skip, int size, List<Float64List> output) {
    final half = size >> 1;
    final actualEnd = math.min(end, type == 2 ? half * output.length : half);
    final partitions = (actualEnd - begin) ~/ partitionSize;
    if (partitions <= 0) return;
    if (skip.every((value) => value)) return;
    final channels =
        type == 2 ? <int>[0] : List.generate(output.length, (i) => i);
    final classDimensions = books[classbook].dimensions;
    final words = (partitions + classDimensions - 1) ~/ classDimensions;
    final cache = List.generate(
        output.length, (_) => List<Int32List?>.filled(words, null));
    for (var stage = 0; stage < 8; stage++) {
      var partition = 0;
      var word = 0;
      while (partition < partitions) {
        if (stage == 0) {
          for (final ch in channels) {
            final scalar = books[classbook].decodeScalar(bits);
            if (scalar >= decodeMap.length) {
              throw const VorbisDecoderException(
                  'invalid residue classification');
            }
            cache[ch][word] = decodeMap[scalar];
          }
        }
        for (var dim = 0;
            dim < classDimensions && partition < partitions;
            dim++, partition++) {
          final offset = begin + partition * partitionSize;
          for (final ch in channels) {
            final classification = cache[ch][word]![dim];
            final bookIndex = stageBooks[classification][stage];
            if (bookIndex >= 0) {
              _write(bits, books[bookIndex], output, ch, offset, partitionSize);
            }
          }
        }
        word++;
      }
    }
  }

  void _write(BitReader bits, _Codebook book, List<Float64List> output,
      int channel, int offset, int count) {
    if (type == 0) {
      final steps = count ~/ book.dimensions;
      final entries = List.generate(steps, (_) => book.decodeScalar(bits));
      for (var dim = 0; dim < book.dimensions; dim++) {
        for (var step = 0; step < steps; step++) {
          output[channel][offset + dim * steps + step] +=
              book.value(entries[step], dim);
        }
      }
    } else if (type == 1) {
      var written = 0;
      while (written < count) {
        final entry = book.decodeScalar(bits);
        for (var dim = 0; dim < book.dimensions && written < count; dim++) {
          output[channel][offset + written++] += book.value(entry, dim);
        }
      }
    } else {
      var written = 0;
      var frame = offset ~/ output.length;
      var ch = offset % output.length;
      while (written < count) {
        final entry = book.decodeScalar(bits);
        for (var dim = 0;
            dim < book.dimensions && written < count;
            dim++, written++) {
          output[ch][frame] += book.value(entry, dim);
          if (++ch == output.length) {
            ch = 0;
            frame++;
          }
        }
      }
    }
  }
}

final class _Mapping {
  _Mapping(BitReader bits, this.channels, List<_Floor1> floors,
      List<_Residue> residues) {
    final submaps = bits.readBool() ? bits.read(4) + 1 : 1;
    final couplingCount = bits.readBool() ? bits.read(8) + 1 : 0;
    magnitude = Int32List(couplingCount);
    angle = Int32List(couplingCount);
    final channelBits = ilog(channels - 1);
    for (var i = 0; i < couplingCount; i++) {
      magnitude[i] = bits.read(channelBits);
      angle[i] = bits.read(channelBits);
      if (magnitude[i] == angle[i] ||
          magnitude[i] >= channels ||
          angle[i] >= channels) {
        throw const VorbisDecoderException('invalid channel coupling');
      }
    }
    if (bits.read(2) != 0) {
      throw const VorbisDecoderException('mapping reserved bits set');
    }
    mux = Int32List(channels);
    if (submaps > 1) {
      for (var ch = 0; ch < channels; ch++) {
        mux[ch] = bits.read(4);
        if (mux[ch] >= submaps) {
          throw const VorbisDecoderException('invalid mapping mux');
        }
      }
    }
    submapFloors = <_Floor1>[];
    submapResidues = <_Residue>[];
    for (var i = 0; i < submaps; i++) {
      bits.read(8);
      final floor = bits.read(8);
      final residue = bits.read(8);
      if (floor >= floors.length || residue >= residues.length) {
        throw const VorbisDecoderException('invalid mapping floor/residue');
      }
      submapFloors.add(floors[floor]);
      submapResidues.add(residues[residue]);
    }
  }

  final int channels;
  late final Int32List magnitude;
  late final Int32List angle;
  late final Int32List mux;
  late final List<_Floor1> submapFloors;
  late final List<_Residue> submapResidues;

  List<Float64List> decode(BitReader bits, int size, int channels,
      {List<Float64List>? output}) {
    final result = output ?? List.generate(channels, (_) => Float64List(size));
    for (final channel in result) {
      channel.fillRange(0, size, 0);
    }
    final floorData =
        List.generate(channels, (ch) => submapFloors[mux[ch]].unpack(bits));
    final skip = List.generate(channels, (ch) => !floorData[ch].used);
    for (var i = 0; i < magnitude.length; i++) {
      if (!skip[magnitude[i]] || !skip[angle[i]]) {
        floorData[magnitude[i]].used = true;
        floorData[angle[i]].used = true;
      }
    }
    for (var submap = 0; submap < submapFloors.length; submap++) {
      submapResidues[submap].decode(bits, skip, size, result);
    }
    for (var i = magnitude.length - 1; i >= 0; i--) {
      final m = result[magnitude[i]];
      final a = result[angle[i]];
      for (var j = 0; j < size >> 1; j++) {
        final oldM = m[j];
        final oldA = a[j];
        if (oldM > 0) {
          if (oldA > 0) {
            m[j] = oldM;
            a[j] = oldM - oldA;
          } else {
            a[j] = oldM;
            m[j] = oldM + oldA;
          }
        } else if (oldA > 0) {
          m[j] = oldM;
          a[j] = oldM + oldA;
        } else {
          a[j] = oldM;
          m[j] = oldM - oldA;
        }
      }
    }
    for (var ch = 0; ch < channels; ch++) {
      if (floorData[ch].used) {
        submapFloors[mux[ch]].apply(floorData[ch], size, result[ch]);
      }
    }
    return result;
  }
}

final class _Mode {
  const _Mode(this.longBlock, this.mapping);
  final bool longBlock;
  final _Mapping mapping;
}

final class _AudioBlock {
  const _AudioBlock(this.pcm, this.size, this.start, this.valid, this.total);
  final List<Float64List> pcm;
  final int size;
  final int start;
  final int valid;
  final int total;
}

void _window(Float64List pcm, int size, int smallSize, bool previousLong,
    bool nextLong) {
  final left = previousLong ? size >> 1 : smallSize >> 1;
  final right = nextLong ? size >> 1 : smallSize >> 1;
  final leftStart = size ~/ 4 - left ~/ 2;
  final rightStart = size * 3 ~/ 4 - right ~/ 2;
  for (var i = 0; i < leftStart; i++) {
    pcm[i] = 0;
  }
  for (var i = 0; i < left; i++) {
    final x = math.sin((i + 0.5) / left * math.pi / 2);
    pcm[leftStart + i] *= math.sin(math.pi / 2 * x * x);
  }
  for (var i = 0; i < right; i++) {
    final x = math.sin((right - i - 0.5) / right * math.pi / 2);
    pcm[rightStart + i] *= math.sin(math.pi / 2 * x * x);
  }
  for (var i = rightStart + right; i < size; i++) {
    pcm[i] = 0;
  }
}

void _inverseMdct(Float64List data, int size) {
  // The IMDCT is a shifted DCT-IV. Put the M input values at odd indices of
  // an 8M-point sequence; its odd DFT bins are exactly the DCT-IV values.
  final m = size >> 1;
  final fftSize = m << 3;
  final scratch =
      _mdctScratch.putIfAbsent(size, () => _MdctScratch(fftSize, m));
  final real = scratch.real..fillRange(0, fftSize, 0);
  final imaginary = scratch.imaginary..fillRange(0, fftSize, 0);
  for (var i = 0; i < m; i++) {
    real[(i << 1) + 1] = data[i];
  }
  _fft(real, imaginary);
  final dct = scratch.dct;
  for (var i = 0; i < m; i++) {
    dct[i] = real[(i << 1) + 1];
  }
  for (var n = 0; n < size; n++) {
    final extended = n + (m >> 1);
    if (extended < m) {
      data[n] = dct[extended];
    } else if (extended < 2 * m) {
      data[n] = -dct[2 * m - 1 - extended];
    } else {
      data[n] = -dct[extended - 2 * m];
    }
  }
}

final _mdctScratch = <int, _MdctScratch>{};

final class _MdctScratch {
  _MdctScratch(int fftSize, int dctSize)
      : real = Float64List(fftSize),
        imaginary = Float64List(fftSize),
        dct = Float64List(dctSize);

  final Float64List real;
  final Float64List imaginary;
  final Float64List dct;
}

void _fft(Float64List real, Float64List imaginary) {
  final length = real.length;
  var reversed = 0;
  for (var i = 1; i < length; i++) {
    var bit = length >> 1;
    while ((reversed & bit) != 0) {
      reversed ^= bit;
      bit >>= 1;
    }
    reversed ^= bit;
    if (i < reversed) {
      final realValue = real[i];
      real[i] = real[reversed];
      real[reversed] = realValue;
      final imaginaryValue = imaginary[i];
      imaginary[i] = imaginary[reversed];
      imaginary[reversed] = imaginaryValue;
    }
  }
  for (var span = 2; span <= length; span <<= 1) {
    final angle = -2 * math.pi / span;
    final stepReal = math.cos(angle);
    final stepImaginary = math.sin(angle);
    final half = span >> 1;
    for (var start = 0; start < length; start += span) {
      var twiddleReal = 1.0;
      var twiddleImaginary = 0.0;
      for (var offset = 0; offset < half; offset++) {
        final even = start + offset;
        final odd = even + half;
        final oddReal =
            real[odd] * twiddleReal - imaginary[odd] * twiddleImaginary;
        final oddImaginary =
            real[odd] * twiddleImaginary + imaginary[odd] * twiddleReal;
        real[odd] = real[even] - oddReal;
        imaginary[odd] = imaginary[even] - oddImaginary;
        real[even] += oddReal;
        imaginary[even] += oddImaginary;
        final nextReal =
            twiddleReal * stepReal - twiddleImaginary * stepImaginary;
        twiddleImaginary =
            twiddleReal * stepImaginary + twiddleImaginary * stepReal;
        twiddleReal = nextReal;
      }
    }
  }
}
