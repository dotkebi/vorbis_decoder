## 0.0.1-dev.0

- Add the Phase 0 deterministic fixture and reference-comparison harness.
- Implement strict Ogg parsing, floor-1 Vorbis setup/audio synthesis, and
  FFT-based IMDCT in pure Dart.
- Add interleaved Float32 decode/probe APIs and explicit Int16 conversion.
- Validate all 11 fixtures, malformed inputs, JS/Wasm compilation, FFI frame
  parity, app SF3 integration, AOT speed, and host peak memory.
