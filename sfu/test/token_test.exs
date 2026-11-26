defmodule AudioFlowSFU.TokenTest do
  use ExUnit.Case, async: true
  alias AudioFlowSFU.Token

  @keys %{"key" => "secret"}

  test "a generated token gives the LiveKit grants back" do
    token =
      Token.generate("key", "secret", "agent-1", "room-a",
        kind: :agent,
        name: "Agent",
        can_publish_data: false
      )

    assert {:ok, grants} = Token.verify(token, @keys)

    assert grants == %{
             identity: "agent-1",
             name: "Agent",
             metadata: "",
             kind: :agent,
             room: "room-a",
             can_publish: true,
             can_subscribe: true,
             can_publish_data: false
           }
  end

  test "bad, expired and grantless tokens are rejected" do
    assert {:error, :invalid_token} = Token.verify("not a jwt", @keys)

    assert {:error, :invalid_token} =
             Token.verify(Token.generate("key", "other", "a", "r"), @keys)

    assert {:error, :invalid_token} =
             Token.verify(Token.generate("unknown", "secret", "a", "r"), @keys)

    assert {:error, :expired} =
             Token.verify(Token.generate("key", "secret", "a", "r", ttl_s: -1), @keys)

    no_join =
      Joken.generate_and_sign!(
        %{},
        %{
          "iss" => "key",
          "sub" => "a",
          "exp" => System.system_time(:second) + 60,
          "video" => %{"room" => "r"}
        },
        Joken.Signer.create("HS256", "secret")
      )

    assert {:error, :invalid_grant} = Token.verify(no_join, @keys)
  end
end
