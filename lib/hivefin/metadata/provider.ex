defmodule Hivefin.Metadata.Provider do
  @moduledoc """
  Behaviour for external metadata providers (TMDB, …).
  """

  @type movie_result :: %{
          required(:tmdb_id) => integer(),
          required(:name) => String.t(),
          optional(:overview) => String.t() | nil,
          optional(:production_year) => integer() | nil,
          optional(:poster_path) => String.t() | nil,
          optional(:backdrop_path) => String.t() | nil,
          optional(:premiere_date) => Date.t() | nil
        }

  @callback search_movie(query :: String.t(), year :: integer() | nil) ::
              {:ok, [movie_result()]} | {:error, term()}

  @callback movie_details(tmdb_id :: integer()) ::
              {:ok, movie_result()} | {:error, term()}

  @callback image_url(path :: String.t() | nil, size :: atom()) :: String.t() | nil
end
