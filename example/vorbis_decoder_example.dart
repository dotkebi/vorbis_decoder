import 'dart:io';

import 'package:vorbis_decoder/vorbis_decoder.dart';

void main(List<String> arguments) {
  if (arguments.isEmpty ||
      arguments.length > 2 ||
      (arguments.length == 2 && arguments[1] != '--int16')) {
    stderr.writeln(
      'Usage: dart run example/vorbis_decoder_example.dart '
      '<input.ogg> [--int16]',
    );
    exitCode = 64;
    return;
  }

  final oggBytes = File(arguments.first).readAsBytesSync();
  final info = probeOgg(oggBytes);

  stdout
    ..writeln('Probe:')
    ..writeln('  channels: ${info.channels}')
    ..writeln('  sample rate: ${info.sampleRate} Hz')
    ..writeln('  frames: ${info.frames}');

  final decoded = decodeOgg(oggBytes);
  stdout
    ..writeln('Decode:')
    ..writeln('  channels: ${decoded.channels}')
    ..writeln('  sample rate: ${decoded.sampleRate} Hz')
    ..writeln('  frames: ${decoded.frames}')
    ..writeln('  Float32 samples: ${decoded.pcm.length}')
    ..writeln('  Float32 bytes: ${decoded.pcm.lengthInBytes}');

  if (arguments.length == 2) {
    final pcm16 = float32ToInt16(decoded.pcm);
    stdout
      ..writeln('Int16 conversion:')
      ..writeln('  samples: ${pcm16.length}')
      ..writeln('  bytes: ${pcm16.lengthInBytes}');
  }
}
