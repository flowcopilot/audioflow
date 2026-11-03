# Dialyzer baseline taken when the check was added (2026-11-03).
# Remove entries as they are fixed.
[
  {"lib/audio_flow/adapters/providers/socket.ex", :pattern_match},
  {"lib/audio_flow/adapters/providers/socket.ex", :pattern_match_cov},
  {"lib/audio_flow/adapters/req_llm.ex", :improper_list_constr},
  {"lib/audio_flow/graph.ex", :call_with_opaque},
  {"lib/audio_flow/graph.ex", :call_without_opaque},
  {"lib/audio_flow/graph/runner.ex", :call_with_opaque},
  {"lib/audio_flow/graph/runner.ex", :call_without_opaque},
  {"lib/audio_flow/tool.ex", :guard_fail}
]
