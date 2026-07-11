#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "stb_vorbis.c"

static int write_f32le(FILE *output, const float *samples, size_t count) {
  const uint16_t endian_probe = 1;
  if (*(const uint8_t *)&endian_probe == 1) {
    return fwrite(samples, sizeof(float), count, output) == count;
  }

  for (size_t index = 0; index < count; index++) {
    uint32_t bits;
    uint8_t bytes[4];
    memcpy(&bits, &samples[index], sizeof(bits));
    bytes[0] = (uint8_t)(bits & 0xffu);
    bytes[1] = (uint8_t)((bits >> 8) & 0xffu);
    bytes[2] = (uint8_t)((bits >> 16) & 0xffu);
    bytes[3] = (uint8_t)((bits >> 24) & 0xffu);
    if (fwrite(bytes, sizeof(bytes), 1, output) != 1) return 0;
  }
  return 1;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s input.ogg output.f32le\n", argv[0]);
    return 64;
  }

  int error = VORBIS__no_error;
  stb_vorbis *decoder = stb_vorbis_open_filename(argv[1], &error, NULL);
  if (decoder == NULL) {
    fprintf(stderr, "stb_vorbis_open_filename failed: %d\n", error);
    return 1;
  }

  const stb_vorbis_info info = stb_vorbis_get_info(decoder);
  if (info.channels <= 0) {
    fprintf(stderr, "invalid channel count: %d\n", info.channels);
    stb_vorbis_close(decoder);
    return 1;
  }

  FILE *output = fopen(argv[2], "wb");
  if (output == NULL) {
    perror("fopen output");
    stb_vorbis_close(decoder);
    return 1;
  }

  const int frames_per_read = 4096;
  const size_t buffer_samples =
      (size_t)frames_per_read * (size_t)info.channels;
  float *buffer = (float *)malloc(buffer_samples * sizeof(float));
  if (buffer == NULL) {
    fprintf(stderr, "out of memory\n");
    fclose(output);
    stb_vorbis_close(decoder);
    return 1;
  }

  int ok = 1;
  for (;;) {
    const int frames = stb_vorbis_get_samples_float_interleaved(
        decoder, info.channels, buffer, (int)buffer_samples);
    if (frames == 0) break;
    const size_t sample_count = (size_t)frames * (size_t)info.channels;
    if (!write_f32le(output, buffer, sample_count)) {
      perror("write output");
      ok = 0;
      break;
    }
  }

  free(buffer);
  if (fclose(output) != 0) ok = 0;
  stb_vorbis_close(decoder);
  return ok ? 0 : 1;
}
