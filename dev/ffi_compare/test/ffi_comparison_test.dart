import 'dart:convert';
import 'dart:io';

import 'package:vorbis_decoder/vorbis_decoder.dart' as dart;
import 'package:vorbis_decoder_ffi/vorbis_decoder_ffi.dart' as ffi;
import 'package:test/test.dart';

import 'package:vorbis_decoder_ffi_compare/ffi_host_library.dart';

void main() {
  final manifest =
      jsonDecode(File('../../test/fixtures/manifest.json').readAsStringSync())
          as Map<String, Object?>;
  final fixtures =
      (manifest['fixtures']! as List<Object?>).cast<Map<String, Object?>>();

  setUpAll(() async {
    ffi.vorbisDecoderLibraryOverride = await buildPublishedFfiHostLibrary();
  });

  for (final fixture in fixtures) {
    final name = fixture['name']! as String;
    test('$name matches the published FFI structure and frame length', () {
      final bytes = File('../../${fixture['oggFile']}').readAsBytesSync();
      final pure = dart.decodeOgg(bytes);
      final native = ffi.decodeOgg(bytes);
      final nativeProbe = ffi.probeOgg(bytes);

      expect(pure.channels, native.channels);
      expect(pure.channels, nativeProbe.channels);
      expect(pure.sampleRate, native.sampleRate);
      expect(pure.sampleRate, nativeProbe.sampleRate);
      expect(pure.frames, native.samplesPerChannel);
      expect(pure.frames, nativeProbe.samplesPerChannel);
      expect(pure.pcm.length, native.pcm.length);
      expect(pure.pcm.length, nativeProbe.totalPcmShorts);
      expect(dart.float32ToInt16(pure.pcm), hasLength(native.pcm.length));
    });
  }
}
