excluded =
  if(System.get_env("AUDIOFLOW_MODEL_TESTS") == "1", do: [], else: [:model]) ++
    if(System.get_env("AUDIOFLOW_PIPELINE_TESTS") == "1", do: [], else: [:pipeline_model]) ++
    if(System.get_env("AUDIOFLOW_DISTRIBUTED_TESTS") == "1", do: [], else: [:distributed]) ++
    if(System.get_env("AUDIOFLOW_HTTP_MODEL_TESTS") == "1", do: [], else: [:http_model])

ExUnit.start(exclude: excluded, assert_receive_timeout: 1000)
