ExUnit.start(exclude: if(System.get_env("AUDIOFLOW_MODEL_TESTS") == "1", do: [], else: [:model]))
