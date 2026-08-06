defmodule Hivefin.Playback.StreamTokenTest do
  use ExUnit.Case, async: true

  alias Hivefin.Playback.StreamToken

  test "sign and verify round-trip" do
    user_id = Ecto.UUID.generate()
    item_id = Ecto.UUID.generate()
    source_id = Ecto.UUID.generate()

    token = StreamToken.sign(user_id, item_id, source_id)
    assert is_binary(token)

    assert {:ok, claims} = StreamToken.verify(token)
    assert claims.user_id == user_id
    assert claims.item_id == item_id
    assert claims.media_source_id == source_id
  end

  test "rejects tampered token" do
    token = StreamToken.sign(Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate())
    assert {:error, _} = StreamToken.verify(token <> "x")
  end

  test "rejects nil/empty" do
    assert {:error, :invalid} = StreamToken.verify(nil)
    assert {:error, _} = StreamToken.verify("")
  end
end
