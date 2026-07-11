import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'src/pcm_metrics.dart';

const _stbCommit = '31c1ad37456438565541f4919958214b6e762fb4';
const _stbSha256 =
    '4c7cb2ff1f7011e9d67950446b7eb9ca044f2e464d76bfbb0b84dd2e23e65636';
const _stbUrl = 'https://raw.githubusercontent.com/nothings/stb/'
    '$_stbCommit/stb_vorbis.c';

const _referenceRmsCeiling = 2e-4;
const _referenceMaxCeiling = 2e-3;
const _minimumRmsLimit = 5e-6;
const _minimumMaxLimit = 5e-5;
const _referenceLimitMultiplier = 4.0;

final class _FixtureSpec {
  const _FixtureSpec({
    required this.name,
    required this.description,
    required this.categories,
    required this.channels,
    required this.sampleRate,
    required this.durationSeconds,
    required this.quality,
    required this.serial,
    this.lavfi,
    this.sourceFile,
    this.sourceLicense = 'CC0-1.0',
    this.sourceAttribution,
    this.expectedAudioPackets,
  }) : assert((lavfi == null) != (sourceFile == null));

  final String name;
  final String description;
  final List<String> categories;
  final String? lavfi;
  final String? sourceFile;
  final String sourceLicense;
  final String? sourceAttribution;
  final int channels;
  final int sampleRate;
  final double durationSeconds;
  final double quality;
  final int serial;
  final int? expectedAudioPackets;

  int get sourceFrames => (durationSeconds * sampleRate).round();
}

const _fixtures = <_FixtureSpec>[
  _FixtureSpec(
    name: 'one_audio_packet_zero',
    description: 'One audio packet after the three mandatory headers; '
        'the first Vorbis audio packet produces no PCM.',
    categories: ['tiny', 'one_audio_packet', 'silence'],
    lavfi: 'anullsrc=r=44100:cl=mono',
    channels: 1,
    sampleRate: 44100,
    durationSeconds: 0,
    quality: 3,
    serial: 13001,
    expectedAudioPackets: 1,
  ),
  _FixtureSpec(
    name: 'tiny_tone_mono_8000',
    description: 'Eight source frames and the minimum non-empty decode.',
    categories: ['tiny', 'tone', 'low_sample_rate'],
    lavfi: 'sine=frequency=1000:sample_rate=8000',
    channels: 1,
    sampleRate: 8000,
    durationSeconds: 0.001,
    quality: 3,
    serial: 13002,
    expectedAudioPackets: 2,
  ),
  _FixtureSpec(
    name: 'tone_mono_8000_low',
    description: 'Low-rate mono tone encoded at the minimum quality.',
    categories: ['tone', 'mono', 'low_sample_rate', 'low_bitrate'],
    lavfi: 'sine=frequency=440:sample_rate=8000',
    channels: 1,
    sampleRate: 8000,
    durationSeconds: 0.4,
    quality: -1,
    serial: 13003,
  ),
  _FixtureSpec(
    name: 'tone_mono_22050_mid',
    description: 'Conventional mono tone at 22.05 kHz.',
    categories: ['tone', 'mono'],
    lavfi: 'sine=frequency=880:sample_rate=22050',
    channels: 1,
    sampleRate: 22050,
    durationSeconds: 0.5,
    quality: 3,
    serial: 13004,
  ),
  _FixtureSpec(
    name: 'dual_tone_stereo_44100_high',
    description: 'Distinct left and right tones at the maximum quality.',
    categories: ['tone', 'stereo', 'channel_coupling', 'high_bitrate'],
    lavfi: 'aevalsrc=0.45*sin(2*PI*440*t)|0.45*sin(2*PI*660*t):s=44100',
    channels: 2,
    sampleRate: 44100,
    durationSeconds: 0.6,
    quality: 10,
    serial: 13005,
  ),
  _FixtureSpec(
    name: 'antiphase_stereo_22050',
    description: 'Opposite-polarity channels expose coupling sign errors.',
    categories: ['tone', 'stereo', 'channel_coupling'],
    lavfi: 'aevalsrc=0.45*sin(2*PI*330*t)|-0.45*sin(2*PI*330*t):s=22050',
    channels: 2,
    sampleRate: 22050,
    durationSeconds: 0.5,
    quality: 4,
    serial: 13006,
  ),
  _FixtureSpec(
    name: 'white_noise_stereo_48000_low',
    description: 'Deterministic broadband white noise at low quality.',
    categories: ['white_noise', 'stereo', 'low_bitrate', 'residue'],
    lavfi: 'anoisesrc=color=white:seed=42:sample_rate=48000',
    channels: 2,
    sampleRate: 48000,
    durationSeconds: 0.5,
    quality: -1,
    serial: 13007,
  ),
  _FixtureSpec(
    name: 'transients_stereo_48000',
    description: 'Asymmetric pulse trains force short/long block changes.',
    categories: ['transient', 'stereo', 'window_transition'],
    lavfi: r'aevalsrc=0.65*lt(mod(t\,0.10)\,0.002)|'
        r'-0.55*lt(mod(t\,0.073)\,0.0015):s=48000',
    channels: 2,
    sampleRate: 48000,
    durationSeconds: 0.75,
    quality: 4,
    serial: 13008,
  ),
  _FixtureSpec(
    name: 'silence_mono_48000',
    description: 'Silence exercises unused-floor and zero-residue paths.',
    categories: ['silence', 'mono'],
    lavfi: 'anullsrc=r=48000:cl=mono',
    channels: 1,
    sampleRate: 48000,
    durationSeconds: 0.25,
    quality: 3,
    serial: 13009,
  ),
  _FixtureSpec(
    name: 'music_stereo_44100',
    description: 'Recorded piano arpeggio with natural attacks and decays.',
    categories: ['music', 'actual_recording', 'stereo', 'channel_coupling'],
    sourceFile: 'tool/fixture_sources/salamander_phrase.flac',
    sourceLicense: 'CC-BY-3.0',
    sourceAttribution: 'Salamander Grand Piano v3, Alexander Holm',
    channels: 2,
    sampleRate: 44100,
    durationSeconds: 3,
    quality: 4,
    serial: 13010,
  ),
  _FixtureSpec(
    name: 'long_stereo_48000',
    description: 'Ten-second stereo chirps exercise sustained decoder state.',
    categories: ['long', 'stereo', 'tone'],
    lavfi: 'aevalsrc=0.25*sin(2*PI*(220+20*t)*t)|'
        '0.25*sin(2*PI*(330+13*t)*t):s=48000',
    channels: 2,
    sampleRate: 48000,
    durationSeconds: 10,
    quality: 3,
    serial: 13011,
  ),
];

Future<void> main(List<String> arguments) async {
  final keepStb = arguments.contains('--keep-stb');
  final unknownArguments =
      arguments.where((argument) => argument != '--keep-stb').toList();
  if (unknownArguments.isNotEmpty) {
    stderr.writeln('Unknown arguments: ${unknownArguments.join(' ')}');
    stderr.writeln('Usage: dart run tool/generate_fixtures.dart [--keep-stb]');
    exitCode = 64;
    return;
  }

  final root = Directory.current.absolute;
  if (!File('${root.path}/pubspec.yaml').existsSync()) {
    throw StateError('Run this script from the package root.');
  }

  await _requireTool('ffmpeg', ['-version']);
  await _requireTool('ffprobe', ['-version']);
  await _requireTool('oggenc', ['--version']);
  await _requireTool('cc', ['--version']);

  final oggDirectory = Directory('${root.path}/test/fixtures/ogg');
  final ffmpegDirectory = Directory(
    '${root.path}/test/fixtures/reference_ffmpeg',
  );
  final stbDirectory = Directory('${root.path}/test/fixtures/reference_stb');
  final temporaryDirectory = Directory(
    '${root.path}/.dart_tool/fixture_generation',
  );
  final referenceBuildDirectory = Directory(
    '${root.path}/.dart_tool/reference',
  );

  for (final directory in [
    oggDirectory,
    ffmpegDirectory,
    temporaryDirectory,
    referenceBuildDirectory,
    if (keepStb) stbDirectory,
  ]) {
    directory.createSync(recursive: true);
  }
  _deleteGeneratedFiles(oggDirectory, '.ogg');
  _deleteGeneratedFiles(ffmpegDirectory, '.f32le');
  if (keepStb) _deleteGeneratedFiles(stbDirectory, '.f32le');

  final stbSource = await _ensureStbSource(referenceBuildDirectory);
  final stbDecoder = File('${referenceBuildDirectory.path}/stb_decode');
  await _run('cc', [
    '-std=c99',
    '-O2',
    '-fno-fast-math',
    '-ffp-contract=off',
    '-I${referenceBuildDirectory.path}',
    '${root.path}/tool/reference/stb_decode.c',
    '-lm',
    '-o',
    stbDecoder.path,
  ]);

  final fixtureRecords = <Map<String, Object?>>[];
  stdout.writeln(
    'fixture                              frames        rms        max',
  );

  for (final fixture in _fixtures) {
    final waveFile = File('${temporaryDirectory.path}/${fixture.name}.wav');
    final oggFile = File('${oggDirectory.path}/${fixture.name}.ogg');
    final ffmpegFile = File('${ffmpegDirectory.path}/${fixture.name}.f32le');
    final stbFile = keepStb
        ? File('${stbDirectory.path}/${fixture.name}.f32le')
        : File('${temporaryDirectory.path}/${fixture.name}.stb.f32le');

    final inputArguments = fixture.lavfi != null
        ? ['-f', 'lavfi', '-i', fixture.lavfi!]
        : ['-i', '${root.path}/${fixture.sourceFile}'];
    await _run('ffmpeg', [
      '-y',
      '-nostdin',
      '-v',
      'error',
      ...inputArguments,
      '-t',
      fixture.durationSeconds.toString(),
      '-ac',
      fixture.channels.toString(),
      '-ar',
      fixture.sampleRate.toString(),
      '-c:a',
      'pcm_s16le',
      waveFile.path,
    ]);
    await _run('oggenc', [
      '--quiet',
      '--serial',
      fixture.serial.toString(),
      '--quality',
      fixture.quality.toString(),
      '--output',
      oggFile.path,
      waveFile.path,
    ]);
    final probe = await _probe(oggFile);
    if (probe.sampleRate != fixture.sampleRate ||
        probe.channels != fixture.channels) {
      throw StateError(
        '${fixture.name}: ffprobe metadata mismatch: '
        '${probe.sampleRate} Hz, ${probe.channels} channels',
      );
    }
    if (fixture.expectedAudioPackets != null &&
        probe.audioPackets != fixture.expectedAudioPackets) {
      throw StateError(
        '${fixture.name}: expected ${fixture.expectedAudioPackets} audio '
        'packets, got ${probe.audioPackets}',
      );
    }

    await _run('ffmpeg', [
      '-y',
      '-nostdin',
      '-v',
      'error',
      '-flags2',
      '+skip_manual',
      '-i',
      oggFile.path,
      '-map',
      '0:a:0',
      '-vn',
      '-sn',
      '-dn',
      '-af',
      'atrim=start_sample=${probe.initialTrimFrames}:'
          'end_sample=${probe.initialTrimFrames + fixture.sourceFrames}',
      '-c:a',
      'pcm_f32le',
      '-f',
      'f32le',
      ffmpegFile.path,
    ]);
    await _run(stbDecoder.path, [oggFile.path, stbFile.path]);

    final ffmpegPcm = decodeF32le(await ffmpegFile.readAsBytes());
    final stbPcm = decodeF32le(await stbFile.readAsBytes());
    final comparison = comparePcm(
      ffmpegPcm,
      stbPcm,
      channels: fixture.channels,
    );
    if (comparison.rmsError > _referenceRmsCeiling ||
        comparison.maxAbsoluteError > _referenceMaxCeiling) {
      throw StateError(
        '${fixture.name}: reference decoders diverged: '
        'rms=${comparison.rmsError}, '
        'max=${comparison.maxAbsoluteError}',
      );
    }

    final decodedFrames = ffmpegPcm.length ~/ fixture.channels;
    if (decodedFrames != fixture.sourceFrames) {
      throw StateError(
        '${fixture.name}: expected ${fixture.sourceFrames} decoded frames, '
        'got $decodedFrames',
      );
    }

    final rmsLimit = math.max(
      _minimumRmsLimit,
      comparison.rmsError * _referenceLimitMultiplier,
    );
    final maxLimit = math.max(
      _minimumMaxLimit,
      comparison.maxAbsoluteError * _referenceLimitMultiplier,
    );
    final stbFileSha256 = await _sha256(stbFile);
    final sourceRecord = await _sourceRecord(root, fixture);

    fixtureRecords.add({
      'name': fixture.name,
      'description': fixture.description,
      'categories': fixture.categories,
      'sampleRate': fixture.sampleRate,
      'channels': fixture.channels,
      'sourceFrames': fixture.sourceFrames,
      'decodedFrames': decodedFrames,
      'audioPackets': probe.audioPackets,
      'initialTrimFrames': probe.initialTrimFrames,
      'encodedBitRate': probe.bitRate,
      'quality': fixture.quality,
      'streamSerial': fixture.serial,
      'oggFile': 'test/fixtures/ogg/${fixture.name}.ogg',
      'referenceFile': 'test/fixtures/reference_ffmpeg/${fixture.name}.f32le',
      'oggBytes': await oggFile.length(),
      'referenceBytes': await ffmpegFile.length(),
      'oggSha256': await _sha256(oggFile),
      'referenceSha256': await _sha256(ffmpegFile),
      'stbReferenceSha256': stbFileSha256,
      'source': sourceRecord,
      'referenceBaseline': comparison.toJson(),
      'dartDecoderLimits': {'rmsError': rmsLimit, 'maxAbsoluteError': maxLimit},
    });

    stdout.writeln(
      '${fixture.name.padRight(36)} '
      '${decodedFrames.toString().padLeft(7)}  '
      '${comparison.rmsError.toStringAsExponential(3).padLeft(10)}  '
      '${comparison.maxAbsoluteError.toStringAsExponential(3).padLeft(10)}',
    );
  }

  final manifest = {
    'schemaVersion': 1,
    'pcmFormat': {
      'encoding': 'IEEE-754 binary32',
      'endianness': 'little',
      'layout': 'interleaved',
    },
    'encoder': {
      'name': 'oggenc/libvorbis',
      'version': await _versionLine('oggenc', ['--version']),
      'serialsAreFixed': true,
    },
    'referenceDecoders': {
      'ffmpeg': {
        'version': await _versionLine('ffmpeg', ['-version']),
        'decoder': 'native vorbis',
        'trimPolicy': 'decode with +skip_manual, then atrim from the first '
            'decoded-frame PTS through the final granule frame count',
      },
      'stbVorbis': {
        'commit': _stbCommit,
        'sourceUrl': _stbUrl,
        'sourceSha256': await _sha256(stbSource),
        'compiler': await _versionLine('cc', ['--version']),
        'compilerFlags': ['-O2', '-fno-fast-math', '-ffp-contract=off'],
      },
    },
    'thresholdPolicy': {
      'comparisonLagFrames': 0,
      'lengthMismatchAllowed': false,
      'referenceRmsCeiling': _referenceRmsCeiling,
      'referenceMaxCeiling': _referenceMaxCeiling,
      'dartLimitMultiplier': _referenceLimitMultiplier,
      'minimumDartRmsLimit': _minimumRmsLimit,
      'minimumDartMaxLimit': _minimumMaxLimit,
    },
    'fixtures': fixtureRecords,
  };

  final manifestFile = File('${root.path}/test/fixtures/manifest.json');
  const encoder = JsonEncoder.withIndent('  ');
  await manifestFile.writeAsString('${encoder.convert(manifest)}\n');

  if (temporaryDirectory.existsSync()) {
    temporaryDirectory.deleteSync(recursive: true);
  }
  stdout.writeln('Wrote ${manifestFile.path}');
}

void _deleteGeneratedFiles(Directory directory, String suffix) {
  for (final entity in directory.listSync()) {
    if (entity is File && entity.path.endsWith(suffix)) {
      entity.deleteSync();
    }
  }
}

Future<File> _ensureStbSource(Directory cacheDirectory) async {
  final destination = File('${cacheDirectory.path}/stb_vorbis.c');
  final override = Platform.environment['STB_VORBIS_SOURCE'];

  if (!destination.existsSync()) {
    if (override != null && override.isNotEmpty) {
      await File(override).copy(destination.path);
    } else {
      stdout.writeln('Downloading pinned stb_vorbis.c...');
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(_stbUrl));
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException(
            'stb_vorbis download returned HTTP ${response.statusCode}',
            uri: Uri.parse(_stbUrl),
          );
        }
        final temporary = File('${destination.path}.partial');
        await response.pipe(temporary.openWrite());
        await temporary.rename(destination.path);
      } finally {
        client.close(force: true);
      }
    }
  }

  final actualSha256 = await _sha256(destination);
  if (actualSha256 != _stbSha256) {
    throw StateError(
      'stb_vorbis.c SHA-256 mismatch: expected $_stbSha256, '
      'got $actualSha256',
    );
  }
  return destination;
}

Future<void> _requireTool(
  String executable,
  List<String> versionArguments,
) async {
  try {
    final result = await Process.run(executable, versionArguments);
    if (result.exitCode != 0) {
      throw StateError('$executable returned ${result.exitCode}');
    }
  } on ProcessException catch (error) {
    throw StateError('Required tool is not available: $executable ($error)');
  }
}

Future<ProcessResult> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      'exit ${result.exitCode}\nstdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
      result.exitCode,
    );
  }
  return result;
}

Future<String> _versionLine(String executable, List<String> arguments) async {
  final result = await _run(executable, arguments);
  final output = '${result.stdout}\n${result.stderr}'.trim();
  return const LineSplitter().convert(output).first;
}

Future<String> _sha256(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

Future<Map<String, Object?>> _sourceRecord(
  Directory root,
  _FixtureSpec fixture,
) async {
  if (fixture.lavfi != null) {
    return {
      'kind': 'generated_lavfi',
      'lavfi': fixture.lavfi,
      'durationSeconds': fixture.durationSeconds,
      'intermediateFormat': 'pcm_s16le',
      'license': fixture.sourceLicense,
    };
  }

  final sourceFile = File('${root.path}/${fixture.sourceFile}');
  if (!sourceFile.existsSync()) {
    throw StateError('Missing fixture source: ${sourceFile.path}');
  }
  return {
    'kind': 'licensed_audio_excerpt',
    'file': fixture.sourceFile,
    'sha256': await _sha256(sourceFile),
    'durationSeconds': fixture.durationSeconds,
    'intermediateFormat': 'pcm_s16le',
    'license': fixture.sourceLicense,
    'attribution': fixture.sourceAttribution,
  };
}

final class _ProbeResult {
  const _ProbeResult({
    required this.sampleRate,
    required this.channels,
    required this.audioPackets,
    required this.bitRate,
    required this.initialTrimFrames,
  });

  final int sampleRate;
  final int channels;
  final int audioPackets;
  final int? bitRate;
  final int initialTrimFrames;
}

Future<_ProbeResult> _probe(File oggFile) async {
  final result = await _run('ffprobe', [
    '-v',
    'error',
    '-count_packets',
    '-select_streams',
    'a:0',
    '-show_entries',
    'stream=codec_name,sample_rate,channels,bit_rate,nb_read_packets',
    '-of',
    'json',
    oggFile.path,
  ]);
  final document = jsonDecode(result.stdout as String) as Map<String, Object?>;
  final streams = document['streams']! as List<Object?>;
  if (streams.length != 1) {
    throw StateError('${oggFile.path}: expected one audio stream');
  }
  final stream = streams.single! as Map<String, Object?>;
  if (stream['codec_name'] != 'vorbis') {
    throw StateError('${oggFile.path}: expected Vorbis codec');
  }
  final defaultFirstPts = await _firstFramePts(oggFile, skipManual: false);
  final manualFirstPts = await _firstFramePts(oggFile, skipManual: true);
  final initialTrimFrames = defaultFirstPts == null || manualFirstPts == null
      ? 0
      : defaultFirstPts - manualFirstPts;
  if (initialTrimFrames < 0) {
    throw StateError('${oggFile.path}: negative initial trim');
  }
  return _ProbeResult(
    sampleRate: int.parse(stream['sample_rate']! as String),
    channels: stream['channels']! as int,
    audioPackets: int.parse(stream['nb_read_packets']! as String),
    bitRate: stream['bit_rate'] == null
        ? null
        : int.tryParse(stream['bit_rate']! as String),
    initialTrimFrames: initialTrimFrames,
  );
}

Future<int?> _firstFramePts(
  File oggFile, {
  required bool skipManual,
}) async {
  final result = await _run('ffprobe', [
    '-v',
    'error',
    if (skipManual) ...['-flags2', '+skip_manual'],
    '-select_streams',
    'a:0',
    '-read_intervals',
    '%+#2',
    '-show_entries',
    'frame=pts',
    '-of',
    'csv=p=0',
    oggFile.path,
  ]);
  final framePts = const LineSplitter()
      .convert((result.stdout as String).trim())
      .map((line) => int.tryParse(line.split(',').first.trim()))
      .whereType<int>();
  return framePts.isEmpty ? null : framePts.first;
}
