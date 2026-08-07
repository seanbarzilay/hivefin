defmodule Hivefin.Jellyfin.IdTest do
  use ExUnit.Case, async: true

  alias Hivefin.Jellyfin.Id

  test "format strips dashes" do
    assert Id.format("3def6bda-7eea-4556-827b-0aa2814ec637") ==
             "3def6bda7eea4556827b0aa2814ec637"
  end

  test "normalize accepts dashed and undashed" do
    dashed = "3def6bda-7eea-4556-827b-0aa2814ec637"
    undashed = "3def6bda7eea4556827b0aa2814ec637"

    assert Id.normalize(dashed) == {:ok, dashed}
    assert Id.normalize(undashed) == {:ok, dashed}
  end

  test "normalize rejects non-uuid" do
    assert Id.normalize("not-a-uuid") == :error
  end
end
