defmodule AudioFlow.Jido do
  @moduledoc """
  Runs Jido agents under the AudioFlow supervision tree.
  """

  use Jido, otp_app: :audio_flow
end
