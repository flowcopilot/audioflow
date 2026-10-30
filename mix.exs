defmodule AudioFlow.MixProject do
  use Mix.Project

  def project do
    [
      app: :audio_flow,
      version: "0.1.0",
      elixir: "~> 1.18",
      build_path: "_build/#{profile()}",
      elixirc_paths: paths(),
      deps: deps(),
      start_permanent: Mix.env() == :prod
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto], mod: {AudioFlow.Application, []}]

  defp paths do
    ["lib"] ++
      if(Mix.env() == :test, do: ["test/support"], else: []) ++
      if(enabled?("AUDIOFLOW_ML"), do: ["lib_ml"], else: []) ++
      if(enabled?("AUDIOFLOW_MEDIA"), do: ["lib_media"], else: [])
  end

  defp deps do
    ml =
      if enabled?("AUDIOFLOW_ML") do
        [
          {:bumblebee, "~> 0.8.0"},
          {:exla, "~> 1.0"},
          {:transmuter,
           github: "georgeguimaraes/transmuter", ref: "231028d9ff6f53bd58fa15d9f24d632258369805"}
        ]
      else
        []
      end

    ml ++
      if(enabled?("AUDIOFLOW_MEDIA"),
        do: [
          {:membrane_core, "~> 1.3"},
          {:membrane_raw_audio_format, "~> 0.12"},
          {:membrane_ffmpeg_swresample_plugin, "~> 0.21.0"},
          {:membrane_portaudio_plugin, "~> 0.19.4"}
        ],
        else: []
      )
  end

  defp enabled?(name), do: System.get_env(name) == "1"

  defp profile do
    case {enabled?("AUDIOFLOW_ML"), enabled?("AUDIOFLOW_MEDIA")} do
      {false, false} -> "core"
      {true, false} -> "ml"
      {false, true} -> "media"
      {true, true} -> "ml_media"
    end
  end
end
