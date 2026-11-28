# AudioFlow contributor guide

AudioFlow is an Elixir voice-agent runtime. Tool versions are in `mise.toml`
(`mise install`; OTP 29 and Elixir 1.20). Docs are Astro Starlight pages in
`site/src/content/docs/docs/`.

## Build profiles

Optional source directories and dependencies turn on with `=1` flags. Each flag
combination has its own build directory, so profiles do not overwrite each other
(`_build/<profile>`). Run `mix deps.get` once for each combination.

- `AUDIOFLOW_ML=1`: `lib_ml` (Bumblebee, EXLA models).
- `AUDIOFLOW_MEDIA=1`: `lib_media` (Membrane, PortAudio).
- `AUDIOFLOW_WEBRTC=1`: `lib_webrtc` (ex_webrtc).
- `AUDIOFLOW_SFU=1`: `lib_sfu` (BEAM SFU pieces).

The directory name is `core`, `ml`, `media` or `ml_media`, plus `_webrtc` and
`_sfu` when those flags are set. Examples: `AUDIOFLOW_MEDIA=1` uses `_build/media`; ML and media together use
`ml_media`; all four use `ml_media_webrtc_sfu`. A source file under a flagged
directory compiles only when its flag is set. Gate its tests the same way.

## Tests

- `mix test` runs the core suite. CI runs it with `MIX_ENV=test`, plus
  `mix run examples/telephony-loopback.exs`.
- Media tests need `AUDIOFLOW_MEDIA=1`, for example
  `AUDIOFLOW_MEDIA=1 mix test test/playback_test.exs test/pcm_source_test.exs`.
- `test/test_helper.exs` excludes slow tags unless a variable is `1`:
  `AUDIOFLOW_MODEL_TESTS` (`:model`), `AUDIOFLOW_PIPELINE_TESTS`
  (`:pipeline_model`, also needs ML and media; artifacts go to
  `AUDIOFLOW_PIPELINE_ARTIFACT_DIR`), `AUDIOFLOW_DISTRIBUTED_TESTS`
  (`:distributed`), `AUDIOFLOW_HTTP_MODEL_TESTS` (`:http_model`).
- External services skip a test when unset: `AUDIOFLOW_POSTGRES_URL` (call
  store), `AUDIOFLOW_PGVECTOR_URL` (`scripts/validate_pgvector.sh` starts a
  database), `AUDIOFLOW_SPEEX_EXECUTABLE`, `AUDIOFLOW_SMART_TURN_MODEL` and
  `AUDIOFLOW_SMART_TURN_PYTHON`.
- Add a regression test with each fix. Do not add tests whose only purpose is
  to show that removed code stays removed.

## Separate Mix projects

`sfu/`, `ui/`, `examples/chat/` and `releases/` have their own `mix.exs`,
deps and formatter. Run `mix deps.get`, `mix format` and `mix test` inside the
directory. The root project does not compile them.

## Git hooks

`hk` (`hk.pkl`) installs with `mise install`. Never skip it with `--no-verify`.

- `commit-msg`: Conventional Commit check.
- `pre-commit`: linters and formatters (rumdl, ruff, oxlint, `mix format`,
  `mix credo diff` against `HEAD`, gitleaks, whitespace, shellcheck).
- `pre-push`: the pre-commit set, plus typecheck, dialyzer, deps audit and tests
  for the core build and for the all-profiles build, and tests for `sfu/`,
  `ui/` and `examples/chat`.
- `hk check` runs the slow set on demand.

## macOS notes

- WebRTC and SFU tests fail with `ExLibSRTP.Native.Nif.unifex_create/0 is undefined`
  when Homebrew links OpenSSL 4. The precompiled libsrtp2 loads
  `@rpath/libcrypto.3.dylib`, and `openssl@3` is keg-only. Link it where the
  loader looks: `ln -s "$(brew --prefix openssl@3)/lib/libcrypto.3.dylib" /opt/homebrew/lib/`.
  Linking it into `deps/bundlex/priv/shared/precompiled/*srtp*/lib/` also works,
  but `mix deps.clean` removes it.
- `examples/chat` picks the native profile on macOS, and its tests expect the demo
  profile. Run them with `CHAT_PROFILE=demo mix test`. The `chat-test` hook step does.

## Benchmarks

`mix bench.hot` runs `bench/hot_paths.exs` (single process CPU paths). Others:
`mix run bench/concurrency.exs` (telephony codecs across 1 to 500 calls) and
`AUDIOFLOW_MEDIA=1 mix run bench/playback.exs` (playback underruns). Compare
runs on an idle machine.

## Commits

Use Conventional Commits with a scope: `perf(playback): keep one pipeline per
output`. Make one commit for each logical change. Do not add co-author or
tool attribution lines.
