defmodule Hivefin.Playback.StreamToken do
  @moduledoc """
  Signed short-lived tokens authorizing progressive video stream requests.

  Tokens are verified independently of the MediaBrowser header so clients can
  pass `api_key` / `Tag` as a query parameter on stream URLs returned from
  PlaybackInfo (Jellyfin client convention).
  """

  @salt "hivefin.stream"
  # Default validity: 6 hours
  @default_max_age 6 * 60 * 60

  @type claims :: %{
          user_id: String.t(),
          item_id: String.t(),
          media_source_id: String.t()
        }

  @doc """
  Signs a stream token for the given user/item/source.

  `exp` is accepted for API compatibility; Phoenix.Token encodes issued-at and
  `verify/2` enforces max age (default #{@default_max_age}s). When `exp` is a
  positive integer it is used as the max_age hint stored only for documentation
  of the intended lifetime — verification still uses `verify/2`'s max_age.
  """
  @spec sign(String.t(), String.t(), String.t(), pos_integer() | nil) :: String.t()
  def sign(user_id, item_id, media_source_id, _exp \\ nil)
      when is_binary(user_id) and is_binary(item_id) and is_binary(media_source_id) do
    Phoenix.Token.sign(endpoint(), @salt, %{
      "uid" => user_id,
      "iid" => item_id,
      "msid" => media_source_id
    })
  end

  @doc """
  Verifies a stream token.

  Returns `{:ok, claims}` or `{:error, reason}` (`:invalid`, `:expired`, …).
  """
  @spec verify(String.t(), keyword()) :: {:ok, claims()} | {:error, atom()}
  def verify(token, opts \\ [])

  def verify(token, opts) when is_binary(token) do
    max_age = Keyword.get(opts, :max_age, @default_max_age)

    case Phoenix.Token.verify(endpoint(), @salt, token, max_age: max_age) do
      {:ok, %{"uid" => uid, "iid" => iid, "msid" => msid}}
      when is_binary(uid) and is_binary(iid) and is_binary(msid) ->
        {:ok, %{user_id: uid, item_id: iid, media_source_id: msid}}

      {:ok, _} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify(_, _), do: {:error, :invalid}

  defp endpoint do
    Application.get_env(:hivefin, :stream_token_endpoint, HivefinWeb.Endpoint)
  end
end
