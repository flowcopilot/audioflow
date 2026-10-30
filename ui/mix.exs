defmodule AudioFlowUI.MixProject do
  use Mix.Project

  # A dashboard for AudioFlow agent graphs, with an MCP endpoint for coding agents.
  # Set LIVE_SHADCN_PATH to a live_shadcn checkout to use local packages.
  @live_shadcn "3ddada48f623d72260360acf115e5d9b5eacd1cf"

  def project do
    [
      app: :audio_flow_ui,
      version: "0.1.0",
      elixir: "~> 1.18",
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application, do: [mod: {AudioFlowUI.Application, []}, extra_applications: [:logger]]

  defp deps do
    [
      {:audio_flow, path: ".."},
      {:sake, "~> 0.4.4"},
      live_shadcn(:live_base),
      live_shadcn(:live_shadcn),
      live_shadcn(:live_ai_elements),
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  # The packages refer to each other by path. `override` replaces those nested
  # path dependencies with the same pinned source.
  defp live_shadcn(name) do
    case System.get_env("LIVE_SHADCN_PATH") do
      nil ->
        {name,
         github: "TudorAndrei/live_shadcn",
         ref: @live_shadcn,
         sparse: "packages/#{name}",
         override: true}

      root ->
        {name, path: Path.join([root, "packages", to_string(name)]), override: true}
    end
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["cmd --cd assets npm install"],
      "assets.build": ["compile", &colocated_hooks/1, "cmd --cd assets npm run build"]
    ]
  end

  # LiveView writes colocated hooks to phoenix-colocated/<app> in the build path.
  defp colocated_hooks(_args), do: System.put_env("NODE_PATH", Mix.Project.build_path())
end
