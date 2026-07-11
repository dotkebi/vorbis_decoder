# vorbis_decoder

A pure Dart package that decodes in-memory Ogg Vorbis data to interleaved
`Float32List` PCM. It is ported from
[NVorbis](https://github.com/NVorbis/NVorbis), and the decoder core under
`lib/` does not depend on Flutter, FFI, or `dart:io`.

- Compiles for the Dart VM, JavaScript, and Wasm
- Supports mono/stereo, Vorbis Floor 1, Residue 0/1/2, and Mapping 0
- Validates Ogg CRCs, lacing, packet continuation, serials, granules, and EOS
- Applies exact final-granule trimming
- Produces interleaved IEEE-754 `Float32List` PCM by default
- Provides an explicit `Float32List` to `Int16List` conversion API
- Defends against malformed inputs and malicious allocation requests

> The current recommendation is: **suitable as a fallback when FFI is not
> available**. Accuracy and the real SF3 application path have been verified,
> but this implementation is slower and uses more memory than FFI. Floor 0
> and several Ogg features are also not supported yet. Replacing an
> application's production FFI decoder with this implementation is not
> currently recommended.

The accuracy, performance, memory, and application-validation evidence is
summarized below.

## Requirements

- Dart SDK `^3.3.0`
- No runtime dependencies

Install the package from pub.dev:

```sh
dart pub add vorbis_decoder
```

## Quick start

```dart
import 'dart:io';

import 'package:vorbis_decoder/vorbis_decoder.dart';

void main() {
  // File access belongs to the caller. The decoder's lib/ does not use dart:io.
  final oggBytes = File('sample.ogg').readAsBytesSync();
  final decoded = decodeOgg(oggBytes);

  print('channels: ${decoded.channels}');
  print('sample rate: ${decoded.sampleRate}');
  print('frames: ${decoded.frames}');
  print('interleaved samples: ${decoded.pcm.length}');

  final pcm16 = float32ToInt16(decoded.pcm);
  print('int16 samples: ${pcm16.length}');
}
```

In browsers or Wasm applications, pass a `Uint8List` obtained from the
network, an asset, drag-and-drop, or another source directly to `probeOgg` or
`decodeOgg`.

## Public API

### `probeOgg`

Validates the Ogg pages and Vorbis headers and returns stream information
without synthesizing PCM.

```dart
final info = probeOgg(oggBytes);

print(info.channels);
print(info.sampleRate);
print(info.frames);       // Frames per channel.
print(info.totalSamples); // frames * channels
```

### `decodeOgg`

Decodes the complete stream in one call.

```dart
final result = decodeOgg(oggBytes);

final Float32List pcm = result.pcm;
assert(pcm.length == result.frames * result.channels);
```

PCM is frame-major and interleaved:

```text
mono:   M0, M1, M2, ...
stereo: L0, R0, L1, R1, L2, R2, ...
```

### `float32ToInt16`

Converts float PCM to signed 16-bit PCM. This is an explicit public API rather
than the decoder's default storage format.

```dart
final Int16List pcm16 = float32ToInt16(result.pcm);
```

Conversion contract:

- Finite inputs are clamped to `[-1.0, +1.0]`.
- Values are rounded to the nearest integer, with exact halves rounded away
  from zero.
- `-1.0 → -32768`
- `+1.0 → +32767`
- `NaN → 0`
- `-Infinity → -32768`
- `+Infinity → +32767`
- Endpoints are handled before multiplication to prevent overflow.

### Error handling

Malformed or unsupported streams throw `VorbisDecoderException`. When
available, the exception includes the relevant Ogg byte offset.

```dart
try {
  final decoded = decodeOgg(oggBytes);
  usePcm(decoded.pcm);
} on VorbisDecoderException catch (error) {
  print(error.message);
  print(error.offset);
}
```

The decoder checks PCM sample-count arithmetic for overflow and unsafe
allocations. The one-shot API limits output to 64 Mi-samples.

## Supported scope

| Feature | Status |
|---|---|
| One logical Ogg Vorbis stream | Supported |
| Vorbis Floor 1 | Supported |
| Residue 0, 1, and 2 | Supported |
| Mapping 0 and channel coupling | Supported |
| Mono and stereo | Verified |
| 8/22.05/44.1/48 kHz | Verified |
| JavaScript compilation | Supported |
| Wasm compilation | Supported |
| Vorbis Floor 0 | Unsupported; rejected explicitly |
| Chained or multiplexed Ogg | Unsupported |
| Seeking | Unsupported |
| Streaming input or incremental PCM | Unsupported |

## Accuracy validation

Eleven pinned fixtures are compared against ffmpeg Float32 reference PCM. The
comparator does not use trimming, padding, lag search, or length tolerances.

The validation checks:

- Channel count and sample rate
- Exact frame count and interleaved PCM length
- Finite values for every sample
- Overall and per-channel RMS error
- Maximum absolute error
- Trimming at both the beginning and end

Results:

| Metric | Result |
|---|---:|
| Fixtures | 11/11 PASS |
| Exact frame/shape comparison with FFI | 11/11 PASS |
| Worst RMS error | `1.379e-7` |
| Worst maximum absolute error | `3.716e-6` |

Per-fixture thresholds and reference metadata are recorded in
[`test/fixtures/manifest.json`](test/fixtures/manifest.json).

## Performance

The following values are p50 measurements from an AOT executable on macOS
26.5.1 arm64 with Dart 3.12.2.

| Input | Pure Dart Float32 | FFI end-to-end | Pure real-time factor |
|---|---:|---:|---:|
| 0.5-second mono | 2.266 ms | 0.151 ms | 220.65× |
| 0.6-second stereo | 11.548 ms | 0.489 ms | 51.96× |
| 3-second music | 54.967 ms | 2.755 ms | 54.58× |
| 10-second stereo | 222.111 ms | 6.450 ms | 45.02× |
| Real SF3 sample, 21.1 seconds | 175.152 ms | 5.382 ms | 120.63× |
| Real SF3 eight-sample set, 191.9 seconds | 1.254 s | 45.420 ms | 153.03× |

The pure Dart decoder is comfortably faster than real time for representative
inputs, but is approximately 15–35 times slower than FFI.

From a repository checkout, run the published-FFI comparison test with:

```sh
./tool/test_ffi_comparison.sh
```

To reproduce the benchmark:

```sh
./tool/benchmark_ffi_comparison.sh
```

Both scripts use the isolated package under `dev/ffi_compare`, resolve
`vorbis_decoder_ffi` from pub.dev, and compile its published C source into a
host library. The root `vorbis_decoder` package therefore remains independent
of Flutter, and `dev/` is excluded from the published archive.

## Memory

The following results use the 10-second stereo fixture. Each case runs in a
fresh VM process.

| Path | Retained PCM | RSS increase | Estimated transient memory excluding input and result |
|---|---:|---:|---:|
| Pure Dart → Float32 | 3,840,000 B | 12,173,312 B | 8,293,775 B |
| Pure Dart → Float32 → Int16 | 5,760,000 B | 14,827,520 B | 9,027,983 B |
| FFI `decodeOgg` | 1,920,000 B | 1,654,784 B | Estimated as 0 due to allocator reuse |
| FFI probe + `decodeOggInto` | 1,920,000 B | 1,228,800 B | Estimated as 0 due to allocator reuse |

The real SF3 lazy-loading path increased host RSS by 42,254,336 bytes. These
are host-side estimates; allocator reuse limits the precision of transient
memory estimates.

## Real SF3 application validation

The decoder was validated by host-side application tests against the real SF3
loading and lazy sample-decoding paths under `03app`. This does not represent
validation on a physical mobile device.

The following checks pass with the real bundled
`salamander-light-v3.sf3`:

- Preset and sample-header loading
- Non-silent `noteOn` output
- Volume or layer changes at different velocities
- Real lazy sample probing, decoding, and cache residency
- Legato, staccato, `noteOff`, and `stopAll` contracts
- No remaining timer or hanging voice after disposal
- Existing 150 MiB eager PCM budget

The production backend remains FFI.

## Malformed input and fuzz validation

Tests verify decoder exceptions for:

- Empty input, non-Ogg bytes, and truncated headers, pages, or packets
- Invalid capture patterns, Ogg versions, CRCs, lacing, or flags
- Continued-packet, serial, and sequence mismatches
- Missing EOS or data after EOS
- Backward granules, unsafe integer ranges, and malicious allocations
- Invalid identification versions, channels, sample rates, or block sizes
- Corrupt setup headers, codebooks, and audio packets
- Sample-count and buffer-size arithmetic overflow

A deterministic 128-case mutation suite uses seed `0x564f5242`. No infinite
loop, VM crash, or leaked `RangeError` was observed.

## Verification commands

```sh
dart analyze
dart test --reporter expanded
dart compile js tool/web_smoke.dart -o /tmp/vorbis_web_smoke.js
dart compile wasm tool/web_smoke.dart -o /tmp/vorbis_web_smoke.wasm
dart run tool/fixture_report.dart
```

Regenerating the fixture corpus additionally requires ffmpeg, ffprobe, oggenc,
and a C compiler:

```sh
dart run tool/generate_fixtures.dart
```

Normal tests read only the committed Ogg files and ffmpeg references. They do
not invoke external executables or access the network.

## Project layout

```text
lib/
  vorbis_decoder.dart
  src/
    decoder.dart
    ogg/
      crc32.dart
      packet_reader.dart
    vorbis/
      bit_reader.dart
      core.dart
test/
  decoder_fixture_test.dart
  malformed_test.dart
  probe_test.dart
  fixtures/
tool/
  fixture_report.dart
  compare_pcm.dart
  generate_fixtures.dart
  web_smoke.dart
```

## Recommendation

The current implementation is a good fit for:

- Web or Wasm environments where FFI is unavailable
- Environments where shipping a native library is undesirable
- Asynchronous lazy SF3 sample decoding as a fallback
- Offline decoding that requires exact frame counts

The existing FFI backend remains a better fit when:

- Selecting the default production backend for a mobile application
- Decode latency and peak memory are important
- Arbitrary Vorbis input may contain Floor 0 or chained Ogg streams

## License and fixture attribution

This package is distributed under the [MIT License](LICENSE). The NVorbis
reference implementation is also MIT-licensed. The recorded-piano
fixture source is derived from Alexander Holm's Salamander Grand Piano v3
under CC BY 3.0. Complete source and license information is recorded in
[`test/fixtures/FIXTURE-LICENSES.md`](test/fixtures/FIXTURE-LICENSES.md).
