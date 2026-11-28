excluded =
  if(System.get_env("AUDIOFLOW_MODEL_TESTS") == "1", do: [], else: [:model]) ++
    if(System.get_env("AUDIOFLOW_PIPELINE_TESTS") == "1", do: [], else: [:pipeline_model]) ++
    if(System.get_env("AUDIOFLOW_DISTRIBUTED_TESTS") == "1", do: [], else: [:distributed]) ++
    if(System.get_env("AUDIOFLOW_HTTP_MODEL_TESTS") == "1", do: [], else: [:http_model])

# assert_receive returns as soon as the message arrives, so a long limit only
# slows failing tests and keeps loaded machines (parallel builds) from flaking.
ExUnit.start(exclude: excluded, assert_receive_timeout: 5000)
