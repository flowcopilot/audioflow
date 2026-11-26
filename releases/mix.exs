defmodule AudioFlowReleases.MixProject do
  use Mix.Project

  # Builds the releases. Each one is hot-upgradable with Castle:
  #   audio_flow_sfu  the SFU alone, the production artifact
  #   audio_flow_dev  the SFU and AudioFlow on one node, for development only
  #                   (an agent restart there also stops the SFU). Build it
  #                   with AUDIOFLOW_SFU=1, which adds :audio_flow with its
  #                   room participant (lib_sfu).
  # The tests in test/ run calls across the SFU and AudioFlow agents; they
  # also need AUDIOFLOW_SFU=1.
  # Set CASTLE_UPGRADE_FROM to a comma-separated list of baselines, such as
  # "tar:artifacts/audio_flow_sfu-0.1.0.tar.gz", to add a relup.
  def project do
    [
      app: :audio_flow_releases,
      version: "0.1.0",
      elixir: "~> 1.18",
      appup: "appup.exs",
      compilers: Mix.compilers() ++ [:appup],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # The tests reuse the SFU test clients.
  defp elixirc_paths(:test),
    do: ["lib", "test/support", Path.expand("../sfu/test/support", __DIR__)]

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:audio_flow_sfu, path: "../sfu"},
      {:castle, "~> 1.3"}
    ] ++
      if(System.get_env("AUDIOFLOW_SFU") == "1",
        do: [{:audio_flow, path: ".."}],
        else: []
      )
  end

  defp releases do
    [
      audio_flow_sfu: fn -> release(audio_flow_sfu: :permanent) end,
      audio_flow_dev: fn -> release(audio_flow_sfu: :permanent, audio_flow: :permanent) end
    ]
  end

  defp release(applications) do
    [
      include_executables_for: [:unix],
      applications: applications ++ [castle: :permanent]
    ]
    |> Keyword.merge(upgrade_from())
    |> Castle.customize()
  end

  defp upgrade_from do
    case String.split(System.get_env("CASTLE_UPGRADE_FROM", ""), ",", trim: true) do
      [] -> []
      baselines -> [upgrade_from: baselines]
    end
  end
end
