defmodule Chat.MixProject do
  use Mix.Project

  # A local LiveView chat over one AudioFlow session per browser tab.
  # Set LIVE_SHADCN_PATH to a live_shadcn checkout to use local packages.
  @live_shadcn "3ddada48f623d72260360acf115e5d9b5eacd1cf"

  def project do
    [
      app: :chat,
      version: "0.1.0",
      elixir: "~> 1.18",
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application, do: [mod: {Chat.Application, []}, extra_applications: [:logger]]

  defp deps do
    [
      {:audio_flow, path: "../.."},
      live_shadcn(:live_base),
      live_shadcn(:live_shadcn),
      live_shadcn(:live_ai_elements),
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:lucide_icons, "~> 2.3"},
      # lucide_icons parses its SVG files at runtime.
      {:lazy_html, ">= 0.1.0"}
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
