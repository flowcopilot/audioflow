defmodule AudioFlowSFU.MixProject do
  use Mix.Project

  # A selective forwarding unit for AudioFlow calls. It does not depend on
  # :audio_flow, so agent nodes can restart while the SFU keeps the media.
  def project do
    [
      app: :audio_flow_sfu,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      elixirc_options: [warnings_as_errors: true],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {AudioFlowSFU.Application, []},
      env: [
        # %{"api key" => "secret"}. Tokens are HS256 JWTs with LiveKit claims.
        api_keys: %{},
        # Start the HTTP endpoint only when a port is set.
        port: nil,
        ice_servers: [],
        max_participants: 100,
        empty_timeout_ms: 30_000,
        # How long a participant waits for its owner or connection to return.
        away_timeout_ms: 30_000
      ]
    ]
  end

  defp deps do
    [
      {:ex_webrtc, "~> 0.18.0"},
      # Data channels in ex_webrtc. A Rust NIF: building it needs cargo.
      {:ex_sctp, "~> 0.1.3"},
      {:bandit, "~> 1.5"},
      {:websock_adapter, "~> 0.5"},
      {:joken, "~> 2.8"},
      {:telemetry, "~> 1.3"}
    ]
  end
end
