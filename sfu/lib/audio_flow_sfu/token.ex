defmodule AudioFlowSFU.Token do
  @moduledoc """
  HS256 access tokens with LiveKit-compatible claims.

  `iss` is the API key, `sub` the participant identity. The `video` grant
  holds `room`, `roomJoin`, `canPublish`, `canSubscribe` and `canPublishData`.
  Optional claims: `name`, `metadata` and `kind` (`"standard"`, `"agent"`,
  `"sip"`). LiveKit server SDKs can make tokens for this SFU.
  """

  @type grants :: %{
          identity: String.t(),
          name: String.t(),
          metadata: String.t(),
          kind: :standard | :agent | :sip,
          room: String.t(),
          can_publish: boolean(),
          can_subscribe: boolean(),
          can_publish_data: boolean()
        }

  @kinds %{"standard" => :standard, "agent" => :agent, "sip" => :sip}

  @doc "Makes a token. Use it in tests, tools and trusted backends."
  def generate(api_key, secret, identity, room, options \\ []) do
    now = System.system_time(:second)

    claims = %{
      "iss" => api_key,
      "sub" => identity,
      "nbf" => now,
      "exp" => now + Keyword.get(options, :ttl_s, 3600),
      "name" => Keyword.get(options, :name, identity),
      "metadata" => Keyword.get(options, :metadata, ""),
      "kind" => Atom.to_string(Keyword.get(options, :kind, :standard)),
      "video" => %{
        "room" => room,
        "roomJoin" => true,
        "canPublish" => Keyword.get(options, :can_publish, true),
        "canSubscribe" => Keyword.get(options, :can_subscribe, true),
        "canPublishData" => Keyword.get(options, :can_publish_data, true)
      }
    }

    Joken.generate_and_sign!(%{}, claims, Joken.Signer.create("HS256", secret))
  end

  @doc "Checks the signature, time window and room grant."
  @spec verify(String.t(), %{String.t() => String.t()}) :: {:ok, grants()} | {:error, atom()}
  def verify(token, keys) when is_binary(token) and is_map(keys) do
    with {:ok, %{"iss" => key}} when is_binary(key) <- Joken.peek_claims(token),
         {:ok, secret} <- Map.fetch(keys, key),
         {:ok, claims} <- Joken.verify(token, Joken.Signer.create("HS256", secret)),
         :ok <- valid_time(claims) do
      grants(claims)
    else
      {:error, :expired} -> {:error, :expired}
      {:error, :not_yet_valid} -> {:error, :not_yet_valid}
      {:error, :invalid_grant} -> {:error, :invalid_grant}
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_, _), do: {:error, :invalid_token}

  defp valid_time(claims) do
    now = System.system_time(:second)

    cond do
      not is_integer(claims["exp"]) or claims["exp"] <= now -> {:error, :expired}
      is_integer(claims["nbf"]) and claims["nbf"] > now + 5 -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  defp grants(%{"sub" => identity, "video" => %{"room" => room, "roomJoin" => true} = video} = c)
       when is_binary(identity) and identity != "" and is_binary(room) and room != "" do
    {:ok,
     %{
       identity: identity,
       name: string(c["name"], identity),
       metadata: string(c["metadata"], ""),
       kind: Map.get(@kinds, c["kind"], :standard),
       room: room,
       can_publish: Map.get(video, "canPublish", true) == true,
       can_subscribe: Map.get(video, "canSubscribe", true) == true,
       can_publish_data: Map.get(video, "canPublishData", true) == true
     }}
  end

  defp grants(_), do: {:error, :invalid_grant}

  defp string(value, _default) when is_binary(value) and value != "", do: value
  defp string(_, default), do: default
end
