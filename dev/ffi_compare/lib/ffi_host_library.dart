import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Builds the host library used by the development-only FFI comparison.
Future<String> buildPublishedFfiHostLibrary() async {
  if (!Platform.isMacOS && !Platform.isLinux) {
    throw UnsupportedError(
      'FFI comparison requires a macOS or Linux host, not '
      '${Platform.operatingSystem}.',
    );
  }

  final outputDirectory = Directory('build/ffi_host')
    ..createSync(recursive: true);
  final output = File(
    '${outputDirectory.path}/libvorbis_decoder_ffi.'
    '${Platform.isMacOS ? 'dylib' : 'so'}',
  ).absolute;
  final packageRoot = await _resolvePublishedPackageRoot();
  if (output.existsSync()) return output.path;

  final arguments = <String>[
    '-O2',
    if (Platform.isMacOS) '-dynamiclib' else ...['-shared', '-fPIC'],
    '-o',
    output.path,
    '${packageRoot.path}/src/vorbis_decoder_ffi.c',
    if (Platform.isLinux) '-lm',
  ];
  final result = await Process.run('cc', arguments);
  if (result.exitCode != 0) {
    throw StateError(
      'Failed to build vorbis_decoder_ffi from pub.dev source:\n'
      '${result.stdout}${result.stderr}',
    );
  }
  return output.path;
}

Future<Directory> _resolvePublishedPackageRoot() async {
  final libraryUri = await Isolate.resolvePackageUri(
    Uri.parse('package:vorbis_decoder_ffi/vorbis_decoder_ffi.dart'),
  );
  if (libraryUri != null && libraryUri.scheme == 'file') {
    return File.fromUri(libraryUri).parent.parent;
  }

  final packageConfig = File('.dart_tool/package_config.json').absolute;
  if (packageConfig.existsSync()) {
    final config =
        jsonDecode(packageConfig.readAsStringSync()) as Map<String, Object?>;
    final packages =
        (config['packages']! as List<Object?>).cast<Map<String, Object?>>();
    final entry = packages
        .where((package) => package['name'] == 'vorbis_decoder_ffi')
        .firstOrNull;
    if (entry != null) {
      final rootUri = Uri.parse(entry['rootUri']! as String);
      return Directory.fromUri(packageConfig.uri.resolveUri(rootUri));
    }
  }

  throw StateError('Unable to locate the published vorbis_decoder_ffi.');
}
