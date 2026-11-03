# Known Dialyzer false positives. Remove an entry once Dialyzer stops reporting it.
[
  # Mint.WebSocket.recv/3 returns raw :gen_tcp/:ssl errors (e.g. `:timeout`) after an
  # HTTP/1 upgrade and Mint.TransportError structs over HTTP/2. Dialyzer infers only
  # the {:ok, ...} branch.
  {"lib/audio_flow/adapters/providers/socket.ex", :pattern_match},
  {"lib/audio_flow/adapters/providers/socket.ex", :pattern_match_cov},
  # On OTP 28+ MapSet.new/0 is a plain map inside, which Dialyzer compares with the
  # opaque :sets.set/1 type.
  {"lib/audio_flow/graph.ex", :call_with_opaque},
  {"lib/audio_flow/graph.ex", :call_without_opaque},
  {"lib/audio_flow/graph/runner.ex", :call_with_opaque},
  {"lib/audio_flow/graph/runner.ex", :call_without_opaque},
  # Jido.Action.Tool's spec says description is String.t(), but an action without a
  # description returns nil, so the `|| ""` fallback is needed.
  {"lib/audio_flow/tool.ex", :guard_fail}
]
