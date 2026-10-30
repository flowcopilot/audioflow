defmodule AudioFlow.Adapters.Function do
  @moduledoc "Adapter for application functions, remote clients, and alternative engines."
  @behaviour AudioFlow.Adapter

  @impl true
  def run(input, options, emit), do: Keyword.fetch!(options, :run).(input, emit)
end
