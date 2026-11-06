defmodule AudioFlowUI.Prerequisites do
  @moduledoc "Configuration checks, not claims of provider or database connectivity."

  alias AudioFlow.Graph.Prerequisites

  def errors(graph),
    do: Prerequisites.errors(graph, AudioFlowUI.catalog())
end
