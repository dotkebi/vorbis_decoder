import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:vorbis_decoder/vorbis_decoder.dart' as pure;
import 'package:vorbis_decoder_ffi/vorbis_decoder_ffi.dart' as ffi;
import 'package:vorbis_decoder_ffi_compare/ffi_host_library.dart';

const _sf3Path =
    '../../../03app/assets/instruments/soundfonts/salamander-light-v3.sf3';

Future<void> main() async {
  final libraryPath = await buildPublishedFfiHostLibrary();
  ffi.vorbisDecoderLibraryOverride = libraryPath;
  final bindings = _VorbisDecoderBindings(
      DynamicLibrary.open(File(libraryPath).absolute.path));
  final cases = <_Case>[
    _fixture('tiny', 'tiny_tone_mono_8000'),
    _fixture('mono', 'tone_mono_22050_mid'),
    _fixture('stereo', 'dual_tone_stereo_44100_high'),
    _fixture('music', 'music_stereo_44100'),
    _fixture('long_10s', 'long_stereo_48000'),
  ];
  final sf3File = File(_sf3Path);
  if (sf3File.existsSync()) {
    final sf3Samples = _extractOggStreams(sf3File.readAsBytesSync());
    cases.addAll([
      _Case('sf3_sample', [sf3Samples.first]),
      _Case('sf3_set_8', sf3Samples.take(8).toList()),
    ]);
  }

  stdout.writeln('environment,${Platform.operatingSystem},'
      '${Platform.operatingSystemVersion.replaceAll(',', ' ')},'
      'dart ${Platform.version.replaceAll(',', ' ')}');
  stdout.writeln('command,dart compile exe bin/benchmark_compare.dart -o '
      'build/benchmark_compare && build/benchmark_compare');
  stdout.writeln(
      'case,input_bytes,frames,channels,audio_seconds,iterations,segment,p50_us,p95_us,realtime_x,frames_per_second');
  for (final benchmarkCase in cases) {
    _runCase(benchmarkCase, bindings);
  }
}

_Case _fixture(String label, String name) => _Case(label, [
      File('../../test/fixtures/ogg/$name.ogg').readAsBytesSync(),
    ]);

void _runCase(_Case benchmarkCase, _VorbisDecoderBindings bindings) {
  final infos = benchmarkCase.inputs.map(pure.probeOgg).toList();
  final decoded = benchmarkCase.inputs.map(pure.decodeOgg).toList();
  final frames = infos.fold<int>(0, (sum, info) => sum + info.frames);
  final seconds =
      infos.fold<double>(0, (sum, info) => sum + info.frames / info.sampleRate);
  final channels = infos.map((info) => info.channels).toSet().join('+');
  final inputBytes = benchmarkCase.inputs.fold<int>(0, (s, b) => s + b.length);
  final iterations = frames > 300000
      ? 7
      : frames > 100000
          ? 12
          : frames < 100
              ? 100
              : 25;
  final contexts = <_NativeContext>[];
  for (var i = 0; i < benchmarkCase.inputs.length; i++) {
    contexts.add(_NativeContext(benchmarkCase.inputs[i], infos[i], bindings));
  }
  try {
    final segments = <String, void Function()>{
      'pure_probe': () {
        for (final bytes in benchmarkCase.inputs) {
          pure.probeOgg(bytes);
        }
      },
      'pure_decode_float32': () {
        for (final bytes in benchmarkCase.inputs) {
          pure.decodeOgg(bytes);
        }
      },
      'pure_float32_to_int16': () {
        for (final result in decoded) {
          pure.float32ToInt16(result.pcm);
        }
      },
      'ffi_input_copy': () {
        for (final context in contexts) {
          context.copyInput();
        }
      },
      'ffi_probe': () {
        for (final bytes in benchmarkCase.inputs) {
          ffi.probeOgg(bytes);
        }
      },
      'ffi_decode_native_into': () {
        for (final context in contexts) {
          context.decodeInto();
        }
      },
      'ffi_native_to_dart_copy': () {
        for (final context in contexts) {
          context.copyNativeOutput();
        }
      },
      'ffi_end_to_end': () {
        for (final bytes in benchmarkCase.inputs) {
          ffi.decodeOgg(bytes);
        }
      },
      'pure_end_to_end_int16': () {
        for (final bytes in benchmarkCase.inputs) {
          pure.float32ToInt16(pure.decodeOgg(bytes).pcm);
        }
      },
    };
    for (final entry in segments.entries) {
      _measure(benchmarkCase.label, inputBytes, frames, channels, seconds,
          iterations, entry.key, entry.value);
    }
  } finally {
    for (final context in contexts) {
      context.dispose();
    }
  }
}

void _measure(
  String label,
  int inputBytes,
  int frames,
  String channels,
  double seconds,
  int iterations,
  String segment,
  void Function() operation,
) {
  for (var i = 0; i < math.min(3, iterations); i++) {
    operation();
  }
  final timings = <int>[];
  for (var i = 0; i < iterations; i++) {
    final stopwatch = Stopwatch()..start();
    operation();
    stopwatch.stop();
    timings.add(stopwatch.elapsedMicroseconds);
  }
  timings.sort();
  final p50 = timings[((timings.length - 1) * 0.50).round()];
  final p95 = timings[((timings.length - 1) * 0.95).round()];
  final realtime = p50 == 0 ? double.infinity : seconds * 1000000 / p50;
  final fps = p50 == 0 ? double.infinity : frames * 1000000 / p50;
  stdout.writeln('$label,$inputBytes,$frames,$channels,'
      '${seconds.toStringAsFixed(6)},$iterations,$segment,$p50,$p95,'
      '${realtime.toStringAsFixed(2)},${fps.toStringAsFixed(0)}');
}

final class _Case {
  const _Case(this.label, this.inputs);
  final String label;
  final List<Uint8List> inputs;
}

typedef _DecodeIntoNative = Int32 Function(
  Pointer<Uint8>,
  Int32,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int16>,
  Int32,
);
typedef _DecodeIntoDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int16>,
  int,
);
typedef _DecodeMemoryNative = Int32 Function(
  Pointer<Uint8>,
  Int32,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Pointer<Int16>>,
);
typedef _DecodeMemoryDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Pointer<Int16>>,
);
typedef _FreePcmNative = Void Function(Pointer<Int16>);
typedef _FreePcmDart = void Function(Pointer<Int16>);

final class _VorbisDecoderBindings {
  _VorbisDecoderBindings(DynamicLibrary library)
      : decodeInto = library.lookupFunction<_DecodeIntoNative, _DecodeIntoDart>(
            'vorbis_decoder_decode_into'),
        decodeMemory =
            library.lookupFunction<_DecodeMemoryNative, _DecodeMemoryDart>(
                'vorbis_decoder_decode_memory'),
        freePcm = library.lookupFunction<_FreePcmNative, _FreePcmDart>(
            'vorbis_decoder_free_pcm');

  final _DecodeIntoDart decodeInto;
  final _DecodeMemoryDart decodeMemory;
  final _FreePcmDart freePcm;
}

final class _NativeContext {
  _NativeContext(this.bytes, pure.VorbisInfo info, this.bindings)
      : input = malloc<Uint8>(bytes.length),
        channels = malloc<Int32>(1),
        sampleRate = malloc<Int32>(1),
        output = malloc<Int16>(info.totalSamples),
        outputPointer = malloc<Pointer<Int16>>(1),
        totalSamples = info.totalSamples {
    copyInput();
    final frames = bindings.decodeMemory(
        input, bytes.length, channels, sampleRate, outputPointer);
    if (frames < 0) throw StateError('native setup decode failed: $frames');
  }

  final Uint8List bytes;
  final _VorbisDecoderBindings bindings;
  final Pointer<Uint8> input;
  final Pointer<Int32> channels;
  final Pointer<Int32> sampleRate;
  final Pointer<Int16> output;
  final Pointer<Pointer<Int16>> outputPointer;
  final int totalSamples;

  void copyInput() => input.asTypedList(bytes.length).setAll(0, bytes);

  void decodeInto() {
    final frames = bindings.decodeInto(
        input, bytes.length, channels, sampleRate, output, totalSamples);
    if (frames < 0) throw StateError('native decode failed: $frames');
  }

  void copyNativeOutput() =>
      Int16List.fromList(outputPointer.value.asTypedList(totalSamples));

  void dispose() {
    bindings.freePcm(outputPointer.value);
    malloc.free(input);
    malloc.free(channels);
    malloc.free(sampleRate);
    malloc.free(output);
    malloc.free(outputPointer);
  }
}

List<Uint8List> _extractOggStreams(Uint8List bytes) {
  final starts = <int>[];
  for (var i = 0; i + 4 <= bytes.length; i++) {
    if (bytes[i] == 0x4f &&
        bytes[i + 1] == 0x67 &&
        bytes[i + 2] == 0x67 &&
        bytes[i + 3] == 0x53 &&
        (bytes[i + 5] & 2) != 0) {
      starts.add(i);
    }
  }
  final streams = <Uint8List>[];
  for (final start in starts) {
    var offset = start;
    while (offset + 27 <= bytes.length) {
      final segmentCount = bytes[offset + 26];
      var body = 0;
      for (var i = 0; i < segmentCount; i++) {
        body += bytes[offset + 27 + i];
      }
      final end = offset + 27 + segmentCount + body;
      if ((bytes[offset + 5] & 4) != 0) {
        streams.add(Uint8List.sublistView(bytes, start, end));
        break;
      }
      offset = end;
    }
  }
  if (streams.isEmpty) throw StateError('no SF3 Ogg streams found');
  return streams;
}
