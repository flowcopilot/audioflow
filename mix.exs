defmodule AudioFlow.MixProject do
  use Mix.Project

  def project do
    [
      app: :audio_flow,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: paths(),
      deps: deps(),
      start_permanent: Mix.env() == :prod
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {AudioFlow.Application, []}]

  defp paths do
    ["lib"] ++
      if(enabled?("AUDIOFLOW_ML"), do: ["lib_ml"], else: []) ++
      if(enabled?("AUDIOFLOW_MEDIA"), do: ["lib_media"], else: [])
  end

  defp deps do
    ml = if enabled?("AUDIOFLOW_ML"), do: [{:bumblebee, "~> 0.8.0"}, {:exla, "~> 1.0"}], else: []

    ml ++
      if(enabled?("AUDIOFLOW_MEDIA"),
        do: [{:membrane_core, "~> 1.3"}, {:membrane_raw_audio_format, "~> 0.12"}],
        else: []
      )
  end

  defp enabled?(name), do: System.get_env(name) == "1"
end
