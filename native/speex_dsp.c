/* Build against SpeexDSP 1.2.1. Packet framing is big-endian length + payload. */
#include <speex/speex_echo.h>
#include <speex/speex_preprocess.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int packet(const void *p, uint32_t n) {
  unsigned char h[4] = {n >> 24, n >> 16, n >> 8, n};
  return fwrite(h, 1, 4, stdout) == 4 && fwrite(p, 1, n, stdout) == n && fflush(stdout) == 0;
}
int main(int argc, char **argv) {
  const int size = 512;
  SpeexEchoState *echo = speex_echo_state_init(size, 3200);
  SpeexPreprocessState *pre = speex_preprocess_state_init(size, 16000);
  if (!echo || !pre) return 1;
  int rate = 16000, denoise = 1, agc = 0, attenuation = -20;
  speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate);
  speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_DENOISE, &denoise);
  speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_AGC, &agc);
  speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &attenuation);
  speex_preprocess_ctl(pre, SPEEX_PREPROCESS_SET_ECHO_STATE, echo);
  if (!packet("ready", 5)) return 1;
  unsigned char h[4], data[2048], out[1024];
  spx_int16_t mic[512], ref[512], clean[512];
  while (fread(h, 1, 4, stdin) == 4) {
    uint32_t n = ((uint32_t)h[0] << 24) | ((uint32_t)h[1] << 16) | ((uint32_t)h[2] << 8) | h[3];
    if (n != sizeof(data) || fread(data, 1, n, stdin) != n) return 2;
    for (int i = 0; i < size; i++) {
      mic[i] = (int16_t)((uint16_t)data[2*i] | ((uint16_t)data[2*i+1] << 8));
      ref[i] = (int16_t)((uint16_t)data[1024+2*i] | ((uint16_t)data[1024+2*i+1] << 8));
    }
    speex_echo_cancellation(echo, mic, ref, clean);
    if (!(argc == 2 && strcmp(argv[1], "aec-only") == 0)) speex_preprocess_run(pre, clean);
    for (int i = 0; i < size; i++) { out[2*i] = clean[i] & 255; out[2*i+1] = (uint16_t)clean[i] >> 8; }
    if (!packet(out, sizeof(out))) break;
  }
  speex_preprocess_state_destroy(pre);
  speex_echo_state_destroy(echo);
  return 0;
}
