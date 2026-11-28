# Linux image for the combined ML, media, WebRTC and SFU build profile and the
# sfu/ project. The Elixir and OTP versions match mise.toml. scripts/docker-test.sh
# builds it and keeps deps, _build and tool caches in named volumes, so the host
# checkout and its macOS builds are never touched.
FROM hexpm/elixir:1.20.4-erlang-29.1.2-debian-bookworm-20261027

# Native deps: bundlex NIFs (FFmpeg, Opus, SRTP precompiled), ex_dtls (OpenSSL
# through pkg-config) and the PortAudio plugin. The ffmpeg CLI builds video
# test fixtures.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl ffmpeg git pkg-config libssl-dev portaudio19-dev \
  && rm -rf /var/lib/apt/lists/*

# sfu/: ex_sctp (WebRTC data channels) is a Rust NIF. Same toolchain as mise.toml.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain 1.100.0
ENV PATH=/root/.cargo/bin:$PATH

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=test \
  AUDIOFLOW_ML=1 \
  AUDIOFLOW_MEDIA=1 \
  AUDIOFLOW_WEBRTC=1 \
  AUDIOFLOW_SFU=1 \
  LANG=C.UTF-8

WORKDIR /app
