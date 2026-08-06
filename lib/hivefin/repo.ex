defmodule Hivefin.Repo do
  use Ecto.Repo,
    otp_app: :hivefin,
    adapter: Ecto.Adapters.Postgres
end
