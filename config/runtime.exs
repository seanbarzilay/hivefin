import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/hivefin start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :hivefin, HivefinWeb.Endpoint, server: true
end

config :hivefin, HivefinWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Admin bootstrap env (read by Hivefin.Accounts.bootstrap_admin/0 when no users exist):
#   HIVEFIN_ADMIN_USER
#   HIVEFIN_ADMIN_PASSWORD
config :hivefin, :admin_bootstrap,
  username: System.get_env("HIVEFIN_ADMIN_USER"),
  password: System.get_env("HIVEFIN_ADMIN_PASSWORD")

if path = System.get_env("HIVEFIN_FFPROBE_PATH") do
  config :hivefin, :ffprobe_path, path
end

if path = System.get_env("HIVEFIN_FFMPEG_PATH") do
  config :hivefin, :ffmpeg_path, path
end

if hw = System.get_env("HIVEFIN_HW_ACCEL") do
  config :hivefin, :hw_accel, hw
end

if max = System.get_env("HIVEFIN_MAX_TRANSCODES") do
  case Integer.parse(max) do
    {n, _} when n > 0 -> config :hivefin, :max_transcodes, n
    _ -> :ok
  end
end

if dir = System.get_env("HIVEFIN_TRANSCODE_DIR") do
  config :hivefin, :transcode_dir, dir
end

if fallback = System.get_env("HIVEFIN_ALLOW_CPU_FALLBACK") do
  config :hivefin,
         :allow_cpu_fallback,
         fallback not in ["false", "0", "no", "FALSE", "No"]
end

if idle = System.get_env("HIVEFIN_SESSION_IDLE_MS") do
  case Integer.parse(idle) do
    {n, _} when n > 0 -> config :hivefin, :session_idle_ms, n
    _ -> :ok
  end
end

if key = System.get_env("HIVEFIN_TMDB_API_KEY") do
  config :hivefin, :tmdb_api_key, key
end

if dir = System.get_env("HIVEFIN_IMAGE_CACHE_DIR") do
  config :hivefin, :image_cache_dir, dir
end

if rate = System.get_env("HIVEFIN_TMDB_RATE_LIMIT") do
  case Integer.parse(rate) do
    {n, _} when n > 0 -> config :hivefin, :tmdb_rate_limit_per_sec, n
    _ -> :ok
  end
end

# Parses HIVEFIN_HTTP_IP / PHX_IP for Bandit. Defaults to loopback in prod.
# Accepts dotted IPv4 (`127.0.0.1`, `0.0.0.0`) or comma-separated IPv6 ints.
parse_http_ip = fn
  nil ->
    {127, 0, 0, 1}

  "" ->
    {127, 0, 0, 1}

  "loopback" ->
    {127, 0, 0, 1}

  "localhost" ->
    {127, 0, 0, 1}

  "any" ->
    {0, 0, 0, 0}

  "0.0.0.0" ->
    {0, 0, 0, 0}

  ip when is_binary(ip) ->
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> tuple
      {:error, _} -> {127, 0, 0, 1}
    end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :hivefin, Hivefin.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :hivefin, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Default bind is loopback. Expose publicly only via reverse proxy on the
  # same host, or set HIVEFIN_HTTP_IP / PHX_IP explicitly (e.g. 0.0.0.0).
  http_ip = parse_http_ip.(System.get_env("HIVEFIN_HTTP_IP") || System.get_env("PHX_IP"))

  config :hivefin, HivefinWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: http_ip
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :hivefin, HivefinWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :hivefin, HivefinWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
