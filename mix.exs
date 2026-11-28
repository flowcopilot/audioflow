defmodule AudioFlow.MixProject do
  use Mix.Project

  def project do
    [
      app: :audio_flow,
      version: "0.1.0",
      elixir: "~> 1.20",
      build_path: "_build/#{profile()}",
      elixirc_paths: paths(),
      deps: deps(),
      aliases: aliases(),
      elixirc_options: [warnings_as_errors: true],
      # Forecastle compiles appup.exs into ebin for host releases that hot-upgrade.
      appup: "appup.exs",
      compilers: Mix.compilers() ++ [:appup],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      docs: docs(),
      start_permanent: Mix.env() == :prod
    ]
  end

  defp docs do
    [
      main: "AudioFlow",
      source_url: "https://github.com/flowcopilot/audioflow",
      extras: ["README.md"]
    ]
  end

  def cli, do: [preferred_envs: [typecheck: :test]]

  defp aliases do
    [
      typecheck: [
        "compile --warnings-as-errors",
        "test --warnings-as-errors --dry-run"
      ],
      "bench.hot": "run bench/hot_paths.exs"
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto], mod: {AudioFlow.Application, []}]

  defp paths do
    ["lib"] ++
      if(Mix.env() == :test, do: ["test/support"], else: []) ++
      if(enabled?("AUDIOFLOW_ML"), do: ["lib_ml"], else: []) ++
      if(enabled?("AUDIOFLOW_MEDIA"), do: ["lib_media"], else: []) ++
      if(enabled?("AUDIOFLOW_WEBRTC"), do: ["lib_webrtc"], else: []) ++
      if(enabled?("AUDIOFLOW_SFU"), do: ["lib_sfu"], else: [])
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

    [
      {:nimble_options, "~> 1.1"},
      {:req_llm, "~> 1.29.0"},
      {:finch, "~> 0.25.0"},
      {:mint_web_socket, "~> 1.0"},
      {:postgrex, "~> 0.22"},
      {:jido, "~> 2.4.0"},
      {:zoi, "~> 0.18.11"},
      {:telemetry, "~> 1.3"},
      {:castle, "~> 1.3", runtime: false},
      {:websock, "~> 0.5.3"},
      # FFmpeg resampling and G.711. Ratio 4.0.1 (via membrane_core) has an
      # optional constraint that predates Decimal 3. Postgrex and Numbers share
      # Decimal 3; media arithmetic compatibility is tested.
      {:decimal, "~> 3.2", override: true},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.21.0"},
      {:membrane_g711_ffmpeg_plugin, "~> 0.1.6"},
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:websock_adapter, "~> 0.5", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.5", only: [:dev, :test], runtime: false},
      {:credo_naming, "~> 2.1", only: [:dev, :test], runtime: false},
      {:blitz_credo_checks, "~> 0.1.10", only: [:dev, :test], runtime: false},
      {:credo_unnecessary_reduce, "~> 0.4.0", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ] ++
      ml ++
      if(enabled?("AUDIOFLOW_WEBRTC"), do: [{:ex_webrtc, "~> 0.18.0"}], else: []) ++
      sfu_deps() ++
      if(enabled?("AUDIOFLOW_MEDIA"),
        do: [
          {:membrane_core, "~> 1.3"},
          {:membrane_raw_audio_format, "~> 0.12"},
          {:membrane_portaudio_plugin, "~> 0.19.4"},
          {:membrane_file_plugin, "~> 0.17.5"},
          {:membrane_mp4_plugin, "~> 0.37.0"},
          {:membrane_h26x_plugin, "~> 0.11.4"},
          {:membrane_h264_ffmpeg_plugin, "~> 0.32.7"},
          {:membrane_ffmpeg_swscale_plugin, "~> 0.16.5"},
          {:membrane_raw_video_format, "~> 0.4.5"},
          {:membrane_opus_plugin, "~> 0.21.0"},
          {:membrane_ogg_plugin, "~> 0.5.2"}
        ],
        else: []
      )
  end

  # Room participants on the AudioFlow SFU encode and decode Opus. The media
  # profile already has the Opus plugin.
  defp sfu_deps do
    if enabled?("AUDIOFLOW_SFU") and not enabled?("AUDIOFLOW_MEDIA"),
      do: [{:membrane_opus_plugin, "~> 0.21.0"}],
      else: []
  end

  defp enabled?(name), do: System.get_env(name) == "1"

  defp profile do
    base =
      case {enabled?("AUDIOFLOW_ML"), enabled?("AUDIOFLOW_MEDIA")} do
        {false, false} -> "core"
        {true, false} -> "ml"
        {false, true} -> "media"
        {true, true} -> "ml_media"
      end

    base <>
      if(enabled?("AUDIOFLOW_WEBRTC"), do: "_webrtc", else: "") <>
      if(enabled?("AUDIOFLOW_SFU"), do: "_sfu", else: "")
  end
end
