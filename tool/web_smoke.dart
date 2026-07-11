import 'dart:typed_data';
import 'package:vorbis_decoder/vorbis_decoder.dart';

void main() {
  // Keep public decoder and conversion entry points reachable in JS/Wasm
  // compilation without requiring file I/O or embedding a fixture.
  final pcm = float32ToInt16(Float32List(0));
  if (pcm.isNotEmpty) throw StateError('unreachable');
  try {
    probeOgg(Uint8List(0));
  } on VorbisDecoderException {
    // Expected smoke path.
  }
}
