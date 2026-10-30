defmodule AudioFlow.Test.DistributedAdapter do
  @behaviour AudioFlow.Adapter

  @impl true
  def run(input, options, emit) do
    send(Keyword.fetch!(options, :owner), {:remote_inference, self(), input})
    emit.("Working.")

    receive do
      :continue -> emit.("Reply from #{node()}.")
    end
  end
end
