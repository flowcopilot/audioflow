#!/usr/bin/env bash
# Generates the LiveKit signal protocol modules from a pinned livekit/protocol
# release. Needs protoc and protoc-gen-elixir:
#   mix escript.install hex protobuf 0.17.1
# The output is committed; run this script only to move to a new release.
set -euo pipefail

version="v1.54.2" # @livekit/protocol 1.54.2, used by livekit-client 2.25.0
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/lib/audio_flow_sfu/livekit/proto"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -sSfL "https://codeload.github.com/livekit/protocol/tar.gz/refs/tags/$version" |
  tar xz -C "$work"
protos="$work/protocol-${version#v}/protobufs"

# Set PROTOC_GEN_ELIXIR when the escripts directory is not on PATH.
plugin="${PROTOC_GEN_ELIXIR:-$(command -v protoc-gen-elixir)}"

rm -rf "$out"
mkdir -p "$out"
protoc \
  --plugin="protoc-gen-elixir=$plugin" \
  --elixir_out="$out" \
  --elixir_opt=package_prefix=audio_flow_sfu.live_kit.proto \
  -I "$protos" \
  livekit_rtc.proto livekit_models.proto livekit_metrics.proto logger/options.proto

# Flatten the tree and use the AudioFlowSFU.LiveKit.Proto namespace.
find "$out" -name '*.pb.ex' -exec mv {} "$out" \;
find "$out" -mindepth 1 -type d -empty -delete
find "$out" -mindepth 1 -type d -exec rm -rf {} +
sed -i.bak \
  -e 's/AudioFlowSfu\.LiveKit\.Proto\.Livekit\./AudioFlowSFU.LiveKit.Proto./g' \
  -e 's/AudioFlowSfu\.LiveKit\.Proto\.Logger\./AudioFlowSFU.LiveKit.Proto.Logger./g' \
  -e 's/AudioFlowSfu\.LiveKit\.Proto\./AudioFlowSFU.LiveKit.Proto./g' \
  "$out"/*.pb.ex
rm -f "$out"/*.bak
cd "$root" && mix format "lib/audio_flow_sfu/livekit/proto/*.ex"
echo "generated $version into $out"
