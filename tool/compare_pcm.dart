import 'dart:convert';
import 'dart:io';

import 'src/pcm_metrics.dart';

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  if (options == null) {
    stderr.writeln(
      'Usage: dart run tool/compare_pcm.dart '
      '--reference FILE --actual FILE --channels N '
      '[--rms-limit N --max-limit N]',
    );
    exitCode = 64;
    return;
  }

  final reference = decodeF32le(
    await File(options.referencePath).readAsBytes(),
  );
  final actual = decodeF32le(await File(options.actualPath).readAsBytes());
  final comparison = comparePcm(
    reference,
    actual,
    channels: options.channels,
  );

  stdout.writeln(const JsonEncoder.withIndent('  ').convert({
    ...comparison.toJson(),
    'frames': comparison.sampleCount ~/ options.channels,
  }));

  final rmsFailed =
      options.rmsLimit != null && comparison.rmsError > options.rmsLimit!;
  final maxFailed = options.maxLimit != null &&
      comparison.maxAbsoluteError > options.maxLimit!;
  if (rmsFailed || maxFailed) exitCode = 1;
}

final class _Options {
  const _Options({
    required this.referencePath,
    required this.actualPath,
    required this.channels,
    required this.rmsLimit,
    required this.maxLimit,
  });

  final String referencePath;
  final String actualPath;
  final int channels;
  final double? rmsLimit;
  final double? maxLimit;
}

_Options? _parseArguments(List<String> arguments) {
  final values = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    if (index + 1 >= arguments.length || !arguments[index].startsWith('--')) {
      return null;
    }
    values[arguments[index]] = arguments[index + 1];
  }

  final referencePath = values['--reference'];
  final actualPath = values['--actual'];
  final channels = int.tryParse(values['--channels'] ?? '');
  final rmsLimit = values['--rms-limit'] == null
      ? null
      : double.tryParse(values['--rms-limit']!);
  final maxLimit = values['--max-limit'] == null
      ? null
      : double.tryParse(values['--max-limit']!);
  final knownKeys = {
    '--reference',
    '--actual',
    '--channels',
    '--rms-limit',
    '--max-limit',
  };

  if (referencePath == null ||
      actualPath == null ||
      channels == null ||
      channels <= 0 ||
      values.keys.any((key) => !knownKeys.contains(key)) ||
      (values.containsKey('--rms-limit') && rmsLimit == null) ||
      (values.containsKey('--max-limit') && maxLimit == null)) {
    return null;
  }

  return _Options(
    referencePath: referencePath,
    actualPath: actualPath,
    channels: channels,
    rmsLimit: rmsLimit,
    maxLimit: maxLimit,
  );
}
