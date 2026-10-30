defmodule AudioFlow.BenchmarkReport do
  @moduledoc "Machine-readable benchmark results and run metadata."
  @columns [
    :phase,
    :run,
    :status,
    :concurrency,
    :duration_us,
    :first_transcript_us,
    :first_text_us,
    :first_audio_us,
    :error
  ]

  def csv(rows) do
    header = Enum.join(@columns, ",") <> "\n"

    lines =
      Enum.map(rows, fn row ->
        {status, error} =
          case row.status do
            :ok -> {"ok", ""}
            {:error, reason} -> {"error", inspect(reason, limit: 50)}
          end

        row = Map.merge(row, %{status: status, error: error})
        Enum.map_join(@columns, ",", &cell(Map.get(row, &1))) <> "\n"
      end)

    IO.iodata_to_binary([header | lines])
  end

  def metadata(audio, options, config_metadata) do
    module_md5 =
      :code.all_loaded()
      |> Enum.filter(fn {module, _} ->
        String.starts_with?(Atom.to_string(module), "Elixir.AudioFlow")
      end)
      |> Map.new(fn {module, _} ->
        {Atom.to_string(module), module.module_info(:md5) |> Base.encode16(case: :lower)}
      end)

    versions =
      :application.loaded_applications()
      |> Enum.filter(fn {name, _, _} ->
        name in [
          :audio_flow,
          :nx,
          :axon,
          :bumblebee,
          :exla,
          :transmuter,
          :membrane_core,
          :finch,
          :mint
        ]
      end)
      |> Map.new(fn {name, _, version} -> {name, to_string(version)} end)

    %{
      schema_version: 1,
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release)),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      schedulers: :erlang.system_info(:schedulers_online),
      versions: versions,
      module_md5: module_md5,
      audio: %{
        sample_rate: audio.sample_rate,
        bytes: byte_size(audio.data),
        sha256: :crypto.hash(:sha256, audio.data) |> Base.encode16(case: :lower)
      },
      options: options,
      config: config_metadata
    }
  end

  defp cell(nil), do: ""
  defp cell(value) when is_integer(value), do: Integer.to_string(value)

  defp cell(value) do
    value = to_string(value)

    if String.contains?(value, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(value, "\"", "\"\"") <> "\"",
      else: value
  end
end
