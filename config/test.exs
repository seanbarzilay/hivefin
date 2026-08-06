import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :hivefin, Hivefin.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "hivefin_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hivefin, HivefinWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Or3maWjDRkdhynhmuXmKAqYQtErvT6e/bKuEH92ehfC1jiiyvzinT+AqyjoItScL",
  server: false

# Faster password hashing in tests
config :argon2_elixir,
  t_cost: 1,
  m_cost: 8

# Skip admin bootstrap on app start in tests
config :hivefin, :bootstrap_admin_on_start, false

# Playback / FFmpeg sessions — keep concurrency low and isolate temp dirs
config :hivefin,
  max_transcodes: 2,
  hw_accel: :none,
  allow_cpu_fallback: true,
  transcode_dir: Path.join(System.tmp_dir!(), "hivefin-transcode-test")

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
