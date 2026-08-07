# Jellyfin WebSocket + Remote Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Jellyfin `/socket` WebSocket endpoint, a live client-session registry, and remote-control command delivery so official clients stop 404-retrying and phone→TV casting works.

**Architecture:** A `WebSock` handler (`HivefinWeb.JellyfinSocket`) is upgraded into from a plain controller action after token auth. Live sessions live in an Elixir `Registry` keyed by access-token id, with fan-out over the existing `Hivefin.PubSub`. HTTP command endpoints look up a target session and push a message into its socket process. No new GenServer.

**Tech Stack:** Elixir, Phoenix 1.8.9, Bandit 1.5, `websock` / `websock_adapter` (already vendored), `Phoenix.PubSub`, `Registry`, Jason, ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-07-jellyfin-websocket-design.md`

## Global Constraints

- Server→client messages MUST include `MessageId` (a UUID string) and `MessageType`. Client→server messages have no `MessageId`.
- `MessageType` is the JSON discriminator. Dispatch MUST be an explicit allowlist — never dynamic dispatch on client input.
- Required fields (no default in the Kotlin SDK) MUST always be present and non-null. Missing keys raise `MissingFieldException` client-side and the message is discarded silently.
  - `ForceKeepAliveMessage`: `Data` (Int), `MessageId`
  - `SessionInfoDto`: `PlayableMediaTypes`, `UserId`, `LastActivityDate`, `LastPlaybackCheckIn`, `IsActive`, `SupportsMediaControl`, `SupportsRemoteControl`, `HasCustomDeviceName`, `SupportedCommands`
  - `PlayRequest`: `PlayCommand`, `ControllingUserId`
  - `PlaystateRequest`: `Command`
  - `GeneralCommand`: `Name`, `ControllingUserId`, `Arguments`
- Session id == access-token id. Never trust a client-supplied `deviceId` as a session key.
- Malformed JSON or an unknown `MessageType` MUST NOT terminate the socket.
- Run `mix format` before every commit. The suite has 8 known pre-existing failures (4 `AndroidTvGaps`, 2 `System/Info`, 2 compat `Path`); do not "fix" them in this work and do not let the count grow.
- `WebSockAdapter.upgrade/4` validates upgrade headers and raises `WebSockAdapter.UpgradeError` unless the request is `GET` with non-empty `host`, `connection: upgrade`, `upgrade: websocket`, non-empty `sec-websocket-key`, and `sec-websocket-version: 13`.

---

## Stage 1 — Transport and keepalive

Outcome: a client holds an open socket without reconnecting; `/socket` without credentials returns 401. No session state yet.

### Task 1: WebSocket message envelope

**Files:**
- Create: `lib/hivefin/jellyfin/ws_message.ex`
- Test: `test/hivefin/jellyfin/ws_message_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Hivefin.Jellyfin.WsMessage.build(type :: String.t(), data :: term()) :: map()` — returns `%{"MessageType" => type, "MessageId" => uuid, "Data" => data}`. Omits `"Data"` entirely when `data` is `nil`.
  - `Hivefin.Jellyfin.WsMessage.encode(type :: String.t(), data :: term()) :: String.t()` — `build/2` JSON-encoded.
  - `Hivefin.Jellyfin.WsMessage.force_keep_alive(seconds :: integer()) :: String.t()`
  - `Hivefin.Jellyfin.WsMessage.keep_alive() :: String.t()`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.Jellyfin.WsMessageTest do
  use ExUnit.Case, async: true

  alias Hivefin.Jellyfin.WsMessage

  test "build/2 always carries MessageType and a UUID MessageId" do
    msg = WsMessage.build("Sessions", [])

    assert msg["MessageType"] == "Sessions"
    assert {:ok, _} = Ecto.UUID.cast(msg["MessageId"])
    assert msg["Data"] == []
  end

  test "build/2 gives each message a distinct MessageId" do
    a = WsMessage.build("KeepAlive", nil)
    b = WsMessage.build("KeepAlive", nil)

    refute a["MessageId"] == b["MessageId"]
  end

  test "build/2 omits Data when nil rather than sending null" do
    msg = WsMessage.build("KeepAlive", nil)

    refute Map.has_key?(msg, "Data")
  end

  test "force_keep_alive/1 encodes the required Int Data and MessageId" do
    decoded = WsMessage.force_keep_alive(60) |> Jason.decode!()

    assert decoded["MessageType"] == "ForceKeepAlive"
    # Data is a non-null Int in the SDK — a missing or null value is discarded.
    assert decoded["Data"] == 60
    assert is_integer(decoded["Data"])
    assert {:ok, _} = Ecto.UUID.cast(decoded["MessageId"])
  end

  test "keep_alive/0 encodes a MessageId" do
    decoded = WsMessage.keep_alive() |> Jason.decode!()

    assert decoded["MessageType"] == "KeepAlive"
    assert {:ok, _} = Ecto.UUID.cast(decoded["MessageId"])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/jellyfin/ws_message_test.exs`
Expected: FAIL — `module Hivefin.Jellyfin.WsMessage is not available`

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule Hivefin.Jellyfin.WsMessage do
  @moduledoc """
  Builds Jellyfin WebSocket message envelopes.

  Server→client messages (`OutboundWebSocketMessage` in jellyfin-sdk-kotlin)
  declare `MessageId` with no default, so kotlinx.serialization treats it as
  required: omit it and the client raises `MissingFieldException` and discards
  the message without a visible error.
  """

  @doc "Builds an envelope. `Data` is omitted entirely when `data` is nil."
  def build(type, data \\ nil) when is_binary(type) do
    base = %{"MessageType" => type, "MessageId" => Ecto.UUID.generate()}

    if is_nil(data), do: base, else: Map.put(base, "Data", data)
  end

  @doc "JSON-encoded `build/2`."
  def encode(type, data \\ nil), do: type |> build(data) |> Jason.encode!()

  @doc "ForceKeepAlive. `Data` is the keepalive window in seconds (required Int)."
  def force_keep_alive(seconds) when is_integer(seconds),
    do: encode("ForceKeepAlive", seconds)

  @doc "KeepAlive reply to a client KeepAlive."
  def keep_alive, do: encode("KeepAlive")
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin/jellyfin/ws_message_test.exs`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
mix format lib/hivefin/jellyfin/ws_message.ex test/hivefin/jellyfin/ws_message_test.exs
git add lib/hivefin/jellyfin/ws_message.ex test/hivefin/jellyfin/ws_message_test.exs
git commit -m "feat: Jellyfin WebSocket message envelope builder"
```

---

### Task 2: Socket handler — keepalive and message dispatch

**Files:**
- Create: `lib/hivefin_web/jellyfin_socket.ex`
- Test: `test/hivefin_web/jellyfin_socket_test.exs`

**Interfaces:**
- Consumes: `Hivefin.Jellyfin.WsMessage.force_keep_alive/1`, `WsMessage.keep_alive/0`.
- Produces:
  - `HivefinWeb.JellyfinSocket` implementing `@behaviour WebSock`.
  - Socket state is a map: `%{user_id: String.t(), session_id: String.t(), device_id: String.t() | nil, subscriptions: MapSet.t()}`.
  - `init/1`, `handle_in/2`, `handle_info/2`, `terminate/2` per the `WebSock` behaviour. Callbacks return `{:push, {:text, iodata}, state}` or `{:ok, state}`.
  - `@keep_alive_seconds 60` — the value advertised in `ForceKeepAlive`.

Callbacks are called directly in tests; no network connection is needed.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule HivefinWeb.JellyfinSocketTest do
  use ExUnit.Case, async: true

  alias HivefinWeb.JellyfinSocket

  defp state do
    %{
      user_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate(),
      device_id: "pixel",
      subscriptions: MapSet.new()
    }
  end

  defp frame(map), do: {Jason.encode!(map), [opcode: :text]}

  test "init pushes ForceKeepAlive so the client starts its keepalive timer" do
    assert {:push, {:text, json}, _state} = JellyfinSocket.init(state())

    decoded = Jason.decode!(json)
    assert decoded["MessageType"] == "ForceKeepAlive"
    assert is_integer(decoded["Data"])
    assert decoded["MessageId"]
  end

  test "KeepAlive is echoed" do
    assert {:push, {:text, json}, _state} =
             JellyfinSocket.handle_in(frame(%{"MessageType" => "KeepAlive"}), state())

    assert Jason.decode!(json)["MessageType"] == "KeepAlive"
  end

  test "unknown MessageType is ignored without closing the socket" do
    s = state()

    assert {:ok, ^s} =
             JellyfinSocket.handle_in(frame(%{"MessageType" => "TotallyMadeUp"}), s)
  end

  test "malformed JSON is ignored without closing the socket" do
    s = state()

    assert {:ok, ^s} = JellyfinSocket.handle_in({"{not json", [opcode: :text]}, s)
  end

  test "a message with no MessageType is ignored" do
    s = state()

    assert {:ok, ^s} = JellyfinSocket.handle_in(frame(%{"Data" => "x"}), s)
  end

  test "binary frames are ignored" do
    s = state()

    assert {:ok, ^s} = JellyfinSocket.handle_in({<<0, 1, 2>>, [opcode: :binary]}, s)
  end

  test "no-op subscription messages are accepted" do
    for type <- [
          "ActivityLogEntryStart",
          "ActivityLogEntryStop",
          "ScheduledTasksInfoStart",
          "ScheduledTasksInfoStop"
        ] do
      s = state()
      assert {:ok, ^s} = JellyfinSocket.handle_in(frame(%{"MessageType" => type}), s)
    end
  end

  test "an arbitrary handle_info message does not crash the socket" do
    s = state()
    assert {:ok, ^s} = JellyfinSocket.handle_info(:some_unexpected_message, s)
  end

  test "terminate returns :ok" do
    assert :ok = JellyfinSocket.terminate(:remote, state())
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin_web/jellyfin_socket_test.exs`
Expected: FAIL — `module HivefinWeb.JellyfinSocket is not available`

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule HivefinWeb.JellyfinSocket do
  @moduledoc """
  Jellyfin WebSocket protocol handler.

  Clients open `/socket`, expect a `ForceKeepAlive` on connect, and then send
  `KeepAlive` on that interval. Message dispatch is an explicit allowlist:
  `MessageType` is untrusted client input.
  """

  @behaviour WebSock

  require Logger

  alias Hivefin.Jellyfin.WsMessage

  # Advertised keepalive window, in seconds.
  @keep_alive_seconds 60

  # Accepted but inert: hivefin has no activity log or task scheduler.
  @noop_types ~w(
    ActivityLogEntryStart ActivityLogEntryStop
    ScheduledTasksInfoStart ScheduledTasksInfoStop
  )

  @impl WebSock
  def init(state) do
    {:push, {:text, WsMessage.force_keep_alive(@keep_alive_seconds)}, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"MessageType" => type}} when is_binary(type) ->
        dispatch(type, state)

      {:ok, _other} ->
        Logger.debug("jellyfin socket: message without MessageType")
        {:ok, state}

      {:error, _} ->
        Logger.debug("jellyfin socket: malformed JSON frame")
        {:ok, state}
    end
  end

  # Jellyfin's protocol is text-only.
  def handle_in({_data, [opcode: _other]}, state), do: {:ok, state}

  @impl WebSock
  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  defp dispatch("KeepAlive", state), do: {:push, {:text, WsMessage.keep_alive()}, state}

  defp dispatch(type, state) when type in @noop_types, do: {:ok, state}

  defp dispatch(type, state) do
    Logger.debug("jellyfin socket: unhandled MessageType #{inspect(type)}")
    {:ok, state}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin_web/jellyfin_socket_test.exs`
Expected: PASS (9 tests)

- [ ] **Step 5: Commit**

```bash
mix format lib/hivefin_web/jellyfin_socket.ex test/hivefin_web/jellyfin_socket_test.exs
git add lib/hivefin_web/jellyfin_socket.ex test/hivefin_web/jellyfin_socket_test.exs
git commit -m "feat: Jellyfin WebSocket handler with keepalive and allowlist dispatch"
```

---

### Task 3: Authenticated upgrade at GET /socket

**Files:**
- Create: `lib/hivefin_web/controllers/jellyfin/socket_controller.ex`
- Modify: `lib/hivefin_web/router.ex` — add the route inside the existing `scope "/", HivefinWeb.Jellyfin` block that uses `pipe_through :jellyfin_stream` (the same block holding the `/Videos/...` routes, around lines 79-85). That pipeline does not force JSON responses and does its own auth, which is what a socket upgrade needs.
- Test: `test/hivefin_web/controllers/jellyfin/socket_test.exs`

**Interfaces:**
- Consumes: `HivefinWeb.Plugs.JellyfinAuth.resolve_token/1` (already public — returns `{:ok, token}` or `:error`), `Hivefin.Accounts.get_access_token/1` (takes the opaque token string, returns an `%AccessToken{}` with `:user` preloaded, or `nil`), `HivefinWeb.JellyfinSocket`.
- Produces: `HivefinWeb.Jellyfin.SocketController.connect/2`. On success upgrades with state `%{user_id:, session_id:, device_id:, subscriptions: MapSet.new()}` where `session_id` is `access_token.id`. On failure responds 401 JSON `%{"error" => "unauthorized"}`.

Note: `Accounts.get_access_token/1` is keyed by the **token string**, not the id. The session id comes from the returned record's `id` field.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule HivefinWeb.Jellyfin.SocketTest do
  use HivefinWeb.ConnCase, async: true

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Socket",
        username: "socketuser",
        password: "password1",
        admin: true
      })

    {:ok, token, access_token} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "pixel",
        device_name: "Pixel",
        client: "Jellyfin for Android",
        client_version: "2.6.3"
      })

    {:ok, user: user, token: token, access_token: access_token}
  end

  # WebSockAdapter.upgrade/4 validates these per RFC6455 and raises otherwise.
  # `host` must be spliced into req_headers directly: Plug.Conn.put_req_header/3
  # raises InvalidHeaderError for "host" (plug/conn.ex:1971), and Plug.Test never
  # mirrors conn.host into req_headers, which the validator reads.
  defp ws_headers(conn) do
    conn
    |> Map.update!(:req_headers, &[{"host", conn.host} | &1])
    |> put_req_header("connection", "upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-key", Base.encode64("0123456789abcdef"))
    |> put_req_header("sec-websocket-version", "13")
  end

  test "upgrades with api_key query param", %{token: token, access_token: at, user: user} do
    conn =
      build_conn()
      |> ws_headers()
      |> get("/socket?api_key=#{token}&deviceId=pixel")

    assert conn.state == :upgraded
    assert_received {_ref, :upgrade, {:websocket, {HivefinWeb.JellyfinSocket, state, _opts}}}
    assert state.session_id == at.id
    assert state.user_id == user.id
  end

  test "upgrades with MediaBrowser Authorization header", %{token: token} do
    conn =
      build_conn()
      |> ws_headers()
      |> put_req_header(
        "authorization",
        ~s(MediaBrowser Client="Jellyfin for Android", Device="Pixel", DeviceId="pixel", Version="2.6.3", Token="#{token}")
      )
      |> get("/socket")

    assert conn.state == :upgraded
    assert_received {_ref, :upgrade, {:websocket, {HivefinWeb.JellyfinSocket, _state, _opts}}}
  end

  test "401s without credentials" do
    conn = build_conn() |> ws_headers() |> get("/socket")

    assert json_response(conn, 401)
    refute conn.state == :upgraded
  end

  test "401s with a bogus token" do
    conn = build_conn() |> ws_headers() |> get("/socket?api_key=not-a-real-token")

    assert json_response(conn, 401)
  end

  test "a client-supplied deviceId is not used as the session key", %{token: token, access_token: at} do
    conn =
      build_conn()
      |> ws_headers()
      |> get("/socket?api_key=#{token}&deviceId=someone-elses-device")

    assert conn.state == :upgraded
    assert_received {_ref, :upgrade, {:websocket, {HivefinWeb.JellyfinSocket, state, _opts}}}
    # Session identity comes from the token, never the query string.
    assert state.session_id == at.id
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin_web/controllers/jellyfin/socket_test.exs`
Expected: FAIL — no route matches `/socket` (the SPA fallback returns a JSON 404 because `socket` is in `WebClientController`'s `@api_roots`)

- [ ] **Step 3a: Add the controller**

```elixir
defmodule HivefinWeb.Jellyfin.SocketController do
  @moduledoc """
  Authenticates `GET /socket` and upgrades it to the Jellyfin WebSocket protocol.

  Clients pass credentials as `api_key` or in the MediaBrowser auth header, so
  token resolution is shared with `JellyfinAuth` rather than reimplemented.
  """

  use HivefinWeb, :controller

  require Logger

  alias Hivefin.Accounts
  alias Hivefin.Accounts.AccessToken
  alias HivefinWeb.JellyfinSocket
  alias HivefinWeb.Plugs.JellyfinAuth

  @socket_timeout_ms 120_000

  def connect(conn, params) do
    with {:ok, token} <- JellyfinAuth.resolve_token(conn),
         %AccessToken{} = access_token <- Accounts.get_access_token(token) do
      log_device_mismatch(access_token, params)

      state = %{
        user_id: access_token.user_id,
        session_id: access_token.id,
        device_id: access_token.device_id,
        subscriptions: MapSet.new()
      }

      conn
      |> WebSockAdapter.upgrade(JellyfinSocket, state, timeout: @socket_timeout_ms)
      |> halt()
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "unauthorized"})
    end
  end

  # The token already identifies the device. A mismatch is worth noticing but
  # must never select the session — that would let a client address another's.
  defp log_device_mismatch(%AccessToken{device_id: device_id}, params) do
    claimed = params["deviceId"] || params["DeviceId"]

    if is_binary(claimed) and is_binary(device_id) and claimed != device_id do
      Logger.debug("jellyfin socket: deviceId #{inspect(claimed)} != token device #{inspect(device_id)}")
    end

    :ok
  end
end
```

- [ ] **Step 3b: Add the route**

In `lib/hivefin_web/router.ex`, inside the existing `scope "/", HivefinWeb.Jellyfin do` block that begins with `pipe_through :jellyfin_stream`, add alongside the `/Videos/...` routes:

```elixir
    # Jellyfin WebSocket. Auth happens in the controller (api_key or header),
    # like the stream routes, so it cannot sit behind the JSON-only pipeline.
    get "/socket", SocketController, :connect
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin_web/controllers/jellyfin/socket_test.exs`
Expected: PASS (5 tests)

- [ ] **Step 5: Verify nothing else regressed**

Run: `mix test`
Expected: 8 failures, all pre-existing (4 `AndroidTvGaps`, 2 `System/Info`, 2 compat `Path`). If any other test fails, stop and fix before committing.

- [ ] **Step 6: Commit**

```bash
mix format lib/hivefin_web/controllers/jellyfin/socket_controller.ex lib/hivefin_web/router.ex test/hivefin_web/controllers/jellyfin/socket_test.exs
git add lib/hivefin_web/controllers/jellyfin/socket_controller.ex lib/hivefin_web/router.ex test/hivefin_web/controllers/jellyfin/socket_test.exs
git commit -m "feat: authenticated GET /socket WebSocket upgrade"
```

- [ ] **Step 7: Verify Stage 1 on the real server**

```bash
git push origin main
ssh root@192.168.1.176 'cd /root/apps/hivefin && git pull --ff-only'
ssh root@192.168.1.176 'cd /root/apps/hivefin && docker compose up -d --build'
```

Then confirm the 404 retry loop is gone. Play something on a client, wait ~30s, and check:

```bash
ssh root@192.168.1.176 'docker logs --since 3m hivefin-hivefin-1 | grep -c "GET /socket"'
```

Expected: a small number (1-2 per client), **not** dozens. Previously this was ~69 per session. A repeating count still means clients are reconnecting.

---

## Stage 2 — Session registry and Sessions push

Outcome: a second client sees the first client's now-playing state, and every emitted `SessionInfoDto` carries all 9 required fields.

### Task 4: Session registry

**Files:**
- Create: `lib/hivefin/sessions.ex`
- Modify: `lib/hivefin/application.ex:26-40` — add the registry to `children`, immediately after the existing `{Registry, keys: :unique, name: Hivefin.Playback.Registry}` line.
- Test: `test/hivefin/sessions_test.exs`

**Interfaces:**
- Consumes: `Phoenix.PubSub` (running as `Hivefin.PubSub`).
- Produces:
  - `Hivefin.Sessions.register(session_id :: String.t(), attrs :: map()) :: :ok` — registers the **calling** process.
  - `Hivefin.Sessions.update(session_id :: String.t(), attrs :: map()) :: :ok` — merges `attrs` into **the calling process's own** entry. `Registry.update_value/3` can only touch the caller's registration, so this is callable *only from the socket process*.
  - `Hivefin.Sessions.put_state(session_id :: String.t(), attrs :: map()) :: :ok | {:error, :no_session}` — asks the socket process(es) for that session to apply `attrs` to their own entry, by sending `{:jellyfin_session_state, attrs}`. This is what request processes (controllers) must use; calling `update/2` from a controller would silently do nothing because the request process owns no registration.
  - `Hivefin.Sessions.list() :: [map()]` — every live session's attrs, each including `:session_id` and `:pid`.
  - `Hivefin.Sessions.pids(session_id :: String.t()) :: [pid()]`
  - `Hivefin.Sessions.push(session_id :: String.t(), message :: term()) :: :ok | {:error, :no_session}` — sends `{:jellyfin_push, message}` to every socket for that session.
  - `Hivefin.Sessions.subscribe() :: :ok` / `Hivefin.Sessions.broadcast_changed() :: :ok` — PubSub topic `"jellyfin:sessions"`, broadcasting `:sessions_changed`.
  - `@registry Hivefin.Sessions.Registry` with `keys: :duplicate`.

Duplicate keys are deliberate: a client reconnecting before its old socket process has terminated must not crash on register.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.SessionsTest do
  use ExUnit.Case, async: false

  alias Hivefin.Sessions

  setup do
    # Registry entries are owned by the registering process, so each test
    # registers from a short-lived task to avoid leaking into the next.
    :ok
  end

  defp spawn_session(session_id, attrs \\ %{}) do
    test = self()

    pid =
      spawn(fn ->
        Sessions.register(session_id, attrs)
        send(test, :registered)

        receive do
          {:jellyfin_push, msg} ->
            send(test, {:got_push, msg})
            Process.sleep(:infinity)

          :stop ->
            :ok
        end
      end)

    assert_receive :registered
    pid
  end

  test "register/2 then list/0 includes the session" do
    id = Ecto.UUID.generate()
    pid = spawn_session(id, %{user_id: "u1", client: "Jellyfin Web"})

    sessions = Sessions.list()
    entry = Enum.find(sessions, &(&1.session_id == id))

    assert entry.user_id == "u1"
    assert entry.client == "Jellyfin Web"
    assert entry.pid == pid

    send(pid, :stop)
  end

  test "pids/1 returns the socket processes for a session" do
    id = Ecto.UUID.generate()
    pid = spawn_session(id)

    assert Sessions.pids(id) == [pid]

    send(pid, :stop)
  end

  test "push/2 delivers to the session's socket" do
    id = Ecto.UUID.generate()
    pid = spawn_session(id)

    assert :ok = Sessions.push(id, %{"MessageType" => "Play"})
    assert_receive {:got_push, %{"MessageType" => "Play"}}

    send(pid, :stop)
  end

  test "push/2 to an unknown session reports no_session" do
    assert {:error, :no_session} = Sessions.push(Ecto.UUID.generate(), %{})
  end

  test "entries disappear when the owning process dies" do
    id = Ecto.UUID.generate()
    pid = spawn_session(id)

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    # Registry cleanup is asynchronous with respect to process death.
    Process.sleep(50)
    assert Sessions.pids(id) == []
  end

  test "two sockets may share a session id without crashing" do
    id = Ecto.UUID.generate()
    a = spawn_session(id)
    b = spawn_session(id)

    assert length(Sessions.pids(id)) == 2

    send(a, :stop)
    send(b, :stop)
  end

  test "subscribe/0 receives broadcast_changed/0" do
    Sessions.subscribe()
    Sessions.broadcast_changed()

    assert_receive :sessions_changed
  end

  test "update/2 merges into the calling process's own entry" do
    id = Ecto.UUID.generate()
    test = self()

    pid =
      spawn(fn ->
        Sessions.register(id, %{user_id: "u1"})
        Sessions.update(id, %{now_playing_item_id: "movie-1"})
        send(test, :updated)
        Process.sleep(:infinity)
      end)

    assert_receive :updated

    entry = Enum.find(Sessions.list(), &(&1.session_id == id))
    assert entry.now_playing_item_id == "movie-1"
    assert entry.user_id == "u1"

    Process.exit(pid, :kill)
  end

  test "put_state/2 asks the socket process to update, since Registry entries are caller-owned" do
    id = Ecto.UUID.generate()
    test = self()

    pid =
      spawn(fn ->
        Sessions.register(id, %{user_id: "u1"})
        send(test, :ready)

        receive do
          {:jellyfin_session_state, attrs} ->
            Sessions.update(id, attrs)
            send(test, :applied)
            Process.sleep(:infinity)
        end
      end)

    assert_receive :ready
    assert :ok = Sessions.put_state(id, %{position_ticks: 42})
    assert_receive :applied

    entry = Enum.find(Sessions.list(), &(&1.session_id == id))
    assert entry.position_ticks == 42

    Process.exit(pid, :kill)
  end

  test "put_state/2 on an unknown session reports no_session" do
    assert {:error, :no_session} = Sessions.put_state(Ecto.UUID.generate(), %{})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/sessions_test.exs`
Expected: FAIL — `module Hivefin.Sessions is not available`

- [ ] **Step 3a: Write the implementation**

```elixir
defmodule Hivefin.Sessions do
  @moduledoc """
  Live client sessions: which clients currently hold a WebSocket, what they can
  be commanded to do, and what they are playing.

  A session id is the client's access-token id, so socket-addressed commands and
  `GET /Sessions` agree without a second identifier scheme.

  Keys are duplicate on purpose: a client that reconnects before its previous
  socket process has terminated must not crash on register.
  """

  @registry Hivefin.Sessions.Registry
  @topic "jellyfin:sessions"

  @doc "Child spec for the application supervision tree."
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc "Registers the calling process as a socket for `session_id`."
  def register(session_id, attrs \\ %{}) when is_binary(session_id) do
    {:ok, _} = Registry.register(@registry, session_id, attrs)
    :ok
  end

  @doc """
  Merges `attrs` into **the calling process's own** entry.

  `Registry.update_value/3` can only modify the caller's registration, so this
  is callable only from the socket process itself. Request processes must use
  `put_state/2`.
  """
  def update(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    Registry.update_value(@registry, session_id, &Map.merge(&1, attrs))
    :ok
  end

  @doc """
  Asks the socket process(es) for `session_id` to merge `attrs` into their entry.

  Used by controllers: a request process owns no registration, so calling
  `update/2` there would silently do nothing.
  """
  def put_state(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    case pids(session_id) do
      [] ->
        {:error, :no_session}

      pids ->
        Enum.each(pids, &send(&1, {:jellyfin_session_state, attrs}))
        :ok
    end
  end

  @doc "All live sessions, each with `:session_id` and `:pid`."
  def list do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {session_id, pid, attrs} ->
      attrs |> Map.put(:session_id, session_id) |> Map.put(:pid, pid)
    end)
  end

  @doc "Socket processes for `session_id`."
  def pids(session_id) when is_binary(session_id) do
    @registry |> Registry.lookup(session_id) |> Enum.map(fn {pid, _attrs} -> pid end)
  end

  @doc "Sends `message` to every socket for `session_id`."
  def push(session_id, message) when is_binary(session_id) do
    case pids(session_id) do
      [] ->
        {:error, :no_session}

      pids ->
        Enum.each(pids, &send(&1, {:jellyfin_push, message}))
        :ok
    end
  end

  @doc "Subscribes the caller to session change notifications."
  def subscribe, do: Phoenix.PubSub.subscribe(Hivefin.PubSub, @topic)

  @doc "Notifies subscribers that the session list or its state changed."
  def broadcast_changed, do: Phoenix.PubSub.broadcast(Hivefin.PubSub, @topic, :sessions_changed)
end
```

- [ ] **Step 3b: Add to the supervision tree**

In `lib/hivefin/application.ex`, in the `children` list, directly after
`{Registry, keys: :unique, name: Hivefin.Playback.Registry},` add:

```elixir
      Hivefin.Sessions,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin/sessions_test.exs`
Expected: PASS (10 tests)

- [ ] **Step 5: Commit**

```bash
mix format lib/hivefin/sessions.ex lib/hivefin/application.ex test/hivefin/sessions_test.exs
git add lib/hivefin/sessions.ex lib/hivefin/application.ex test/hivefin/sessions_test.exs
git commit -m "feat: live client session registry"
```

---

### Task 5: SessionInfoDto required fields

**Files:**
- Modify: `lib/hivefin/jellyfin/dto/session.ex` — add `LastPlaybackCheckIn`, route the map through required-field defaults.
- Create: `test/hivefin/jellyfin/dto/session_test.exs`

**Interfaces:**
- Consumes: `Hivefin.Accounts.AccessToken`.
- Produces:
  - `Hivefin.Jellyfin.Dto.Session.from_access_token/1` — unchanged name and arity; now always emits the 9 required `SessionInfoDto` fields.
  - `Hivefin.Jellyfin.Dto.Session.required_keys/0 :: [String.t()]` — the 9 required key names, for reuse by the socket/command tests.

`LastActivityDate` and `LastPlaybackCheckIn` are required non-null `DateTime`s. When a token has no timestamp, fall back to `DateTime.utc_now/0` rather than emitting null.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.Jellyfin.Dto.SessionTest do
  use Hivefin.DataCase, async: true

  alias Hivefin.Jellyfin.Dto.Session, as: SessionDto

  # Listed literally from jellyfin-sdk-kotlin SessionInfoDto — properties with
  # no default value. Never read from the implementation's own defaults.
  @required ~w(
    PlayableMediaTypes UserId LastActivityDate LastPlaybackCheckIn IsActive
    SupportsMediaControl SupportsRemoteControl HasCustomDeviceName SupportedCommands
  )

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Sess",
        username: "sessdto",
        password: "password1",
        admin: true
      })

    {:ok, _token, access_token} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "dev",
        device_name: "Dev",
        client: "Jellyfin Web",
        client_version: "10.9.0"
      })

    {:ok, access_token: Hivefin.Repo.preload(access_token, :user)}
  end

  test "carries every required SessionInfoDto field, non-null", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    for key <- @required do
      assert Map.has_key?(dto, key), "SessionInfoDto missing required key #{key}"
      refute is_nil(dto[key]), "SessionInfoDto required key #{key} is null"
    end
  end

  test "required_keys/0 matches the SDK list", %{access_token: _at} do
    assert Enum.sort(SessionDto.required_keys()) == Enum.sort(@required)
  end

  test "LastPlaybackCheckIn is an ISO8601 timestamp", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    assert {:ok, _, _} = DateTime.from_iso8601(dto["LastPlaybackCheckIn"])
  end

  test "Id is the access token id", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    assert dto["Id"] == Hivefin.Jellyfin.Id.format(at.id)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/jellyfin/dto/session_test.exs`
Expected: FAIL — `SessionInfoDto missing required key LastPlaybackCheckIn`, and `required_keys/0` undefined

- [ ] **Step 3: Write the implementation**

In `lib/hivefin/jellyfin/dto/session.ex`, add the required-key list and default
merge, and emit `LastPlaybackCheckIn`. Replace the module body's public function
with:

```elixir
  # Properties jellyfin-sdk-kotlin declares on SessionInfoDto with no default
  # value: kotlinx.serialization requires the key to be present, and a missing
  # one makes the client discard the session silently.
  @required %{
    "PlayableMediaTypes" => ["Video"],
    "UserId" => nil,
    "LastActivityDate" => nil,
    "LastPlaybackCheckIn" => nil,
    "IsActive" => true,
    "SupportsMediaControl" => false,
    "SupportsRemoteControl" => false,
    "HasCustomDeviceName" => false,
    "SupportedCommands" => []
  }

  @doc "Required SessionInfoDto key names."
  def required_keys, do: Map.keys(@required)

  @doc """
  Builds a SessionInfoDto from an `AccessToken` (user should be preloaded).
  """
  def from_access_token(%AccessToken{} = at) do
    user = at.user
    last_activity = datetime(at.updated_at || at.inserted_at) || now()

    %{
      "Id" => Hivefin.Jellyfin.Id.format(at.id),
      "UserId" => Hivefin.Jellyfin.Id.format(at.user_id),
      "UserName" => user_name(user),
      "Client" => at.client || "Unknown Client",
      "DeviceId" => at.device_id || "unknown",
      "DeviceName" => at.device_name || "Unknown Device",
      "ApplicationVersion" => at.client_version || "0.0.0",
      "IsActive" => true,
      "SupportsMediaControl" => false,
      "SupportsRemoteControl" => false,
      "HasCustomDeviceName" => false,
      "LastActivityDate" => last_activity,
      "LastPlaybackCheckIn" => last_activity,
      "ServerId" => Hivefin.Jellyfin.Id.format(Hivefin.Jellyfin.SystemInfo.server_id()),
      "PlayableMediaTypes" => ["Video"],
      "SupportedCommands" => [],
      "Capabilities" => %{
        "PlayableMediaTypes" => ["Video"],
        "SupportedCommands" => [],
        "SupportsMediaControl" => false,
        "SupportsPersistentIdentifier" => true
      }
    }
    |> then(&Map.merge(@required, drop_nils(&1)))
  end

  defp drop_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
```

Keep the existing `user_name/1` and `datetime/1` private helpers.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin/jellyfin/dto/session_test.exs`
Expected: PASS (4 tests)

- [ ] **Step 5: Confirm the pre-existing /Sessions failures are unchanged**

Run: `mix test test/hivefin_web/controllers/jellyfin/android_tv_gaps_test.exs`
Expected: still 4 failures, all on ID format (`3f2470acd2fa…` vs `3f2470ac-d2fa-…`). These are out of scope per spec §8. If the count or reason changed, investigate before committing.

- [ ] **Step 6: Commit**

```bash
mix format lib/hivefin/jellyfin/dto/session.ex test/hivefin/jellyfin/dto/session_test.exs
git add lib/hivefin/jellyfin/dto/session.ex test/hivefin/jellyfin/dto/session_test.exs
git commit -m "fix: SessionInfoDto carries all SDK-required fields"
```

---

### Task 6: Register sockets and push Sessions

**Files:**
- Modify: `lib/hivefin_web/jellyfin_socket.ex` — register on `init`, handle `SessionsStart`/`SessionsStop`, handle `{:jellyfin_push, msg}` and `:sessions_changed`.
- Modify: `test/hivefin_web/jellyfin_socket_test.exs` — add cases.
- Test: same file.

**Interfaces:**
- Consumes: `Hivefin.Sessions.register/2`, `Sessions.subscribe/0`, `Sessions.list/0`, `Hivefin.Jellyfin.WsMessage.encode/2`, `Hivefin.Accounts.list_access_tokens/1`, `Hivefin.Jellyfin.Dto.Session.from_access_token/1`.
- Produces: no new public functions. Socket state gains nothing beyond the existing `:subscriptions` `MapSet`, which now holds `"Sessions"` when subscribed.

`init/1` now returns `{:push, [{:text, force_keep_alive}, ...], state}` only if more than one frame is needed; keep it as a single `ForceKeepAlive` push and register as a side effect.

- [ ] **Step 1: Write the failing test (append to the existing file)**

```elixir
  describe "session registration and Sessions push" do
    test "init registers the socket so it appears in Sessions.list/0" do
      s = state()

      assert {:push, _frame, _state} = JellyfinSocket.init(s)

      assert Enum.any?(Hivefin.Sessions.list(), &(&1.session_id == s.session_id))
    end

    test "SessionsStart pushes a Sessions message and records the subscription" do
      s = state()
      {:push, _, s} = JellyfinSocket.init(s)

      assert {:push, {:text, json}, new_state} =
               JellyfinSocket.handle_in(
                 frame(%{"MessageType" => "SessionsStart", "Data" => "0,1500"}),
                 s
               )

      decoded = Jason.decode!(json)
      assert decoded["MessageType"] == "Sessions"
      assert is_list(decoded["Data"])
      assert MapSet.member?(new_state.subscriptions, "Sessions")
    end

    test "SessionsStop clears the subscription" do
      s = state()
      {:push, _, s} = JellyfinSocket.init(s)
      {:push, _, s} = JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStart"}), s)

      assert {:ok, new_state} =
               JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStop"}), s)

      refute MapSet.member?(new_state.subscriptions, "Sessions")
    end

    test "a jellyfin_push message is forwarded to the client verbatim" do
      s = state()

      assert {:push, {:text, json}, ^s} =
               JellyfinSocket.handle_info(
                 {:jellyfin_push, %{"MessageType" => "Play", "MessageId" => "x"}},
                 s
               )

      assert Jason.decode!(json)["MessageType"] == "Play"
    end

    test "sessions_changed pushes Sessions only when subscribed" do
      s = state()

      # Not subscribed: no push.
      assert {:ok, ^s} = JellyfinSocket.handle_info(:sessions_changed, s)

      subscribed = %{s | subscriptions: MapSet.new(["Sessions"])}

      assert {:push, {:text, json}, _} =
               JellyfinSocket.handle_info(:sessions_changed, subscribed)

      assert Jason.decode!(json)["MessageType"] == "Sessions"
    end

    test "every session in a Sessions push carries the required fields" do
      s = state()
      {:push, _, s} = JellyfinSocket.init(s)
      {:push, {:text, json}, _} = JellyfinSocket.handle_in(frame(%{"MessageType" => "SessionsStart"}), s)

      for session <- Jason.decode!(json)["Data"],
          key <- Hivefin.Jellyfin.Dto.Session.required_keys() do
        assert Map.has_key?(session, key), "SessionInfoDto missing #{key}"
        refute is_nil(session[key]), "SessionInfoDto #{key} is null"
      end
    end
  end
```

Because these touch the registry and the database, change the top of the file
from `use ExUnit.Case, async: true` to:

```elixir
  use Hivefin.DataCase, async: false
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin_web/jellyfin_socket_test.exs`
Expected: FAIL — the socket does not register, and `SessionsStart` is treated as unknown

- [ ] **Step 3: Write the implementation**

In `lib/hivefin_web/jellyfin_socket.ex`:

```elixir
  alias Hivefin.Accounts
  alias Hivefin.Jellyfin.Dto.Session, as: SessionDto
  alias Hivefin.Sessions

  @impl WebSock
  def init(state) do
    :ok =
      Sessions.register(state.session_id, %{
        user_id: state.user_id,
        device_id: state.device_id
      })

    :ok = Sessions.subscribe()
    Sessions.broadcast_changed()

    {:push, {:text, WsMessage.force_keep_alive(@keep_alive_seconds)}, state}
  end
```

Add these dispatch clauses **above** the catch-all `dispatch/2`:

```elixir
  defp dispatch("SessionsStart", state) do
    state = %{state | subscriptions: MapSet.put(state.subscriptions, "Sessions")}
    {:push, {:text, sessions_message(state)}, state}
  end

  defp dispatch("SessionsStop", state) do
    {:ok, %{state | subscriptions: MapSet.delete(state.subscriptions, "Sessions")}}
  end
```

Add `handle_info/2` clauses **above** the existing catch-all:

```elixir
  @impl WebSock
  def handle_info({:jellyfin_push, message}, state) do
    {:push, {:text, Jason.encode!(message)}, state}
  end

  def handle_info(:sessions_changed, state) do
    if MapSet.member?(state.subscriptions, "Sessions") do
      {:push, {:text, sessions_message(state)}, state}
    else
      {:ok, state}
    end
  end
```

And the payload builder plus `terminate/2`:

```elixir
  defp sessions_message(state) do
    sessions =
      [user_id: state.user_id]
      |> Accounts.list_access_tokens()
      |> Enum.map(&SessionDto.from_access_token/1)

    WsMessage.encode("Sessions", sessions)
  end

  @impl WebSock
  def terminate(_reason, _state) do
    # Registry entries are owned by this process and cleared on exit; the
    # broadcast tells other sockets the list changed.
    Sessions.broadcast_changed()
    :ok
  end
```

Remove the old `terminate/2` clause so only one remains.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin_web/jellyfin_socket_test.exs`
Expected: PASS (15 tests)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones.

- [ ] **Step 6: Commit**

```bash
mix format lib/hivefin_web/jellyfin_socket.ex test/hivefin_web/jellyfin_socket_test.exs
git add lib/hivefin_web/jellyfin_socket.ex test/hivefin_web/jellyfin_socket_test.exs
git commit -m "feat: register sockets and push Sessions list"
```

Do not deploy yet — Stage 2 completes at Task 7, which adds the now-playing
state that makes the `Sessions` push useful.

---

### Task 7: Now-playing state in Sessions

**Files:**
- Modify: `lib/hivefin_web/jellyfin_socket.ex` — handle `{:jellyfin_session_state, attrs}`.
- Modify: `lib/hivefin_web/controllers/jellyfin/sessions_controller.ex` — `playing/2`, `progress/2`, `stopped/2` record state and broadcast. These three actions already exist for playback *reporting*; this adds the session-state side effect without changing their responses.
- Modify: `lib/hivefin/jellyfin/dto/session.ex` — emit `NowPlayingItem` / `PlayState` when known.
- Test: `test/hivefin_web/jellyfin_socket_test.exs`, `test/hivefin/jellyfin/dto/session_test.exs`

**Interfaces:**
- Consumes: `Hivefin.Sessions.put_state/2`, `Sessions.update/2`, `Sessions.broadcast_changed/0`, `Hivefin.Library.LibraryContext.get_item/1`, `Hivefin.Jellyfin.Dto.BaseItem.from_item/2`.
- Produces:
  - `Hivefin.Jellyfin.Dto.Session.from_access_token/2` gains a `:state` option: `%{item_id: String.t() | nil, position_ticks: integer() | nil, is_paused: boolean()}`. When `item_id` resolves to an item, the DTO includes `"NowPlayingItem"` (a `BaseItemDto`) and `"PlayState"` (`%{"PositionTicks" => …, "IsPaused" => …, "CanSeek" => true}`). Both keys are omitted when there is nothing playing — they are nullable-with-default in the SDK, so absence is safe.

`NowPlayingItem` and `PlayState` are optional in `SessionInfoDto`; only the 9 required keys must always be present.

- [ ] **Step 1: Write the failing test (append to session_test.exs)**

```elixir
  test "omits NowPlayingItem when nothing is playing", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    refute Map.has_key?(dto, "NowPlayingItem")
    refute Map.has_key?(dto, "PlayState")
  end

  test "includes PlayState when a position is known", %{access_token: at} do
    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: nil, position_ticks: 500, is_paused: true}
      )

    assert dto["PlayState"]["PositionTicks"] == 500
    assert dto["PlayState"]["IsPaused"] == true
    assert dto["PlayState"]["CanSeek"] == true
  end

  test "still carries every required field with state present", %{access_token: at} do
    dto =
      SessionDto.from_access_token(at,
        state: %{item_id: nil, position_ticks: 1, is_paused: false}
      )

    for key <- @required do
      assert Map.has_key?(dto, key), "missing #{key}"
      refute is_nil(dto[key]), "#{key} is null"
    end
  end
```

Append to `jellyfin_socket_test.exs`:

```elixir
  test "a session_state message updates the registry entry" do
    s = state()
    {:push, _, s} = JellyfinSocket.init(s)

    assert {:ok, ^s} =
             JellyfinSocket.handle_info(
               {:jellyfin_session_state, %{position_ticks: 999, is_paused: true}},
               s
             )

    entry = Enum.find(Hivefin.Sessions.list(), &(&1.session_id == s.session_id))
    assert entry.position_ticks == 999
    assert entry.is_paused == true
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/hivefin/jellyfin/dto/session_test.exs test/hivefin_web/jellyfin_socket_test.exs`
Expected: FAIL — `from_access_token/2` does not accept `:state`, and the socket ignores `{:jellyfin_session_state, _}`

- [ ] **Step 3a: Handle state updates in the socket**

In `lib/hivefin_web/jellyfin_socket.ex`, add above the catch-all `handle_info/2`:

```elixir
  def handle_info({:jellyfin_session_state, attrs}, state) do
    # Registry entries are caller-owned, so the socket applies its own update.
    Sessions.update(state.session_id, attrs)
    Sessions.broadcast_changed()
    {:ok, state}
  end
```

- [ ] **Step 3b: Emit NowPlayingItem / PlayState**

In `lib/hivefin/jellyfin/dto/session.ex`, first widen the signature — Task 5
created it as `from_access_token/1`, and this is where the options argument is
introduced. The default keeps every existing caller working:

```elixir
  def from_access_token(%AccessToken{} = at, opts \\ []) do
```

Then, after building the base map, merge in the playback state:

```elixir
    state = Keyword.get(opts, :state)
```

and pipe the map through:

```elixir
    |> put_play_state(state)
```

with:

```elixir
  defp put_play_state(dto, nil), do: dto

  defp put_play_state(dto, %{} = state) do
    position = Map.get(state, :position_ticks)
    item_id = Map.get(state, :item_id)

    dto
    |> maybe_put("PlayState", play_state(position, Map.get(state, :is_paused, false)))
    |> maybe_put("NowPlayingItem", now_playing_item(item_id))
  end

  defp play_state(nil, _paused), do: nil

  defp play_state(position, paused) when is_integer(position) do
    %{"PositionTicks" => position, "IsPaused" => !!paused, "CanSeek" => true}
  end

  defp now_playing_item(nil), do: nil

  defp now_playing_item(item_id) when is_binary(item_id) do
    case Hivefin.Library.LibraryContext.get_item(item_id) do
      nil -> nil
      item -> Hivefin.Jellyfin.Dto.BaseItem.from_item(item)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
```

- [ ] **Step 3c: Record state from the reporting endpoints**

In `lib/hivefin_web/controllers/jellyfin/sessions_controller.ex`, in each of
`playing/2`, `progress/2`, and `stopped/2`, before returning the existing
response, add a call to record state on the reporting client's own session.
The session id is the caller's access token id:

```elixir
  # Records now-playing state on the caller's own session so other clients can
  # see it. put_state/2 (not update/2) because this runs in a request process.
  defp record_session_state(conn, attrs) do
    case conn.assigns[:current_access_token] do
      %{id: session_id} -> Sessions.put_state(session_id, attrs)
      _ -> :ok
    end

    :ok
  end
```

Call it as:
- in `playing/2`: `record_session_state(conn, %{item_id: params["ItemId"], position_ticks: params["PositionTicks"], is_paused: false})`
- in `progress/2`: `record_session_state(conn, %{item_id: params["ItemId"], position_ticks: params["PositionTicks"], is_paused: !!params["IsPaused"]})`
- in `stopped/2`: `record_session_state(conn, %{item_id: nil, position_ticks: nil, is_paused: false})`

Add `alias Hivefin.Sessions` at the top of the module.

`conn.assigns.current_access_token` is already set by `HivefinWeb.Plugs.JellyfinAuth`.

- [ ] **Step 3d: Include state in the Sessions push**

In `lib/hivefin_web/jellyfin_socket.ex`, change `sessions_message/1` to pass each
session's recorded state:

```elixir
  defp sessions_message(state) do
    live = Map.new(Sessions.list(), &{&1.session_id, &1})

    sessions =
      [user_id: state.user_id]
      |> Accounts.list_access_tokens()
      |> Enum.map(fn at ->
        SessionDto.from_access_token(at, state: session_state(live[at.id]))
      end)

    WsMessage.encode("Sessions", sessions)
  end

  defp session_state(nil), do: nil

  defp session_state(entry) do
    %{
      item_id: Map.get(entry, :item_id),
      position_ticks: Map.get(entry, :position_ticks),
      is_paused: Map.get(entry, :is_paused, false)
    }
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/hivefin/jellyfin/dto/session_test.exs test/hivefin_web/jellyfin_socket_test.exs`
Expected: PASS (7 + 16 tests)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones. In particular the existing
`POST /Sessions/Playing/Progress` tests must still pass — the state recording is
a side effect and must not change their responses.

- [ ] **Step 6: Commit and deploy Stage 2**

```bash
mix format lib/hivefin_web/jellyfin_socket.ex lib/hivefin/jellyfin/dto/session.ex lib/hivefin_web/controllers/jellyfin/sessions_controller.ex test/hivefin/jellyfin/dto/session_test.exs test/hivefin_web/jellyfin_socket_test.exs
git add -A
git commit -m "feat: report now-playing state over the session socket"
git push origin main
ssh root@192.168.1.176 'cd /root/apps/hivefin && git pull --ff-only'
ssh root@192.168.1.176 'cd /root/apps/hivefin && docker compose up -d --build'
```

Verify on devices: start playback on the TV, then open the web client and
confirm it shows the TV as playing that title.

---

## Stage 3 — Remote control commands

Outcome: "play on device" from one client starts playback on another; pause/seek/volume reach the target.

### Task 8: Command payload builders

**Files:**
- Create: `lib/hivefin/jellyfin/ws_command.ex`
- Test: `test/hivefin/jellyfin/ws_command_test.exs`

**Interfaces:**
- Consumes: `Hivefin.Jellyfin.WsMessage.build/2`.
- Produces:
  - `Hivefin.Jellyfin.WsCommand.play(controlling_user_id :: String.t(), params :: map()) :: map()` — a `Play` envelope whose `Data` is a `PlayRequest`.
  - `Hivefin.Jellyfin.WsCommand.playstate(command :: String.t(), params :: map()) :: map()` — a `Playstate` envelope.
  - `Hivefin.Jellyfin.WsCommand.general(name :: String.t(), controlling_user_id :: String.t(), arguments :: map()) :: map()` — a `GeneralCommand` envelope.
  - `Hivefin.Jellyfin.WsCommand.play_commands/0`, `playstate_commands/0` — valid enum values.

`PlayRequest` requires `PlayCommand` and `ControllingUserId`. `PlaystateRequest` requires `Command`. `GeneralCommand` requires all three of `Name`, `ControllingUserId`, `Arguments` — `Arguments` must be an object, never null.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hivefin.Jellyfin.WsCommandTest do
  use ExUnit.Case, async: true

  alias Hivefin.Jellyfin.WsCommand

  @user "11111111-1111-1111-1111-111111111111"

  test "play/2 carries the required PlayRequest fields" do
    msg = WsCommand.play(@user, %{"ItemIds" => ["abc"], "PlayCommand" => "PlayNow"})

    assert msg["MessageType"] == "Play"
    assert msg["MessageId"]
    data = msg["Data"]
    assert data["PlayCommand"] == "PlayNow"
    assert data["ControllingUserId"] == @user
    assert data["ItemIds"] == ["abc"]
  end

  test "play/2 defaults PlayCommand to PlayNow rather than omitting it" do
    data = WsCommand.play(@user, %{"ItemIds" => ["abc"]})["Data"]

    assert data["PlayCommand"] == "PlayNow"
  end

  test "play/2 rejects an unknown PlayCommand" do
    assert {:error, :invalid_command} =
             WsCommand.play(@user, %{"PlayCommand" => "Teleport"})
  end

  test "playstate/2 carries the required Command field" do
    msg = WsCommand.playstate("Seek", %{"SeekPositionTicks" => 100})

    assert msg["MessageType"] == "Playstate"
    assert msg["Data"]["Command"] == "Seek"
    assert msg["Data"]["SeekPositionTicks"] == 100
  end

  test "playstate/2 rejects an unknown command" do
    assert {:error, :invalid_command} = WsCommand.playstate("Explode", %{})
  end

  test "general/3 always sends Arguments as an object" do
    msg = WsCommand.general("SetVolume", @user, %{})

    assert msg["MessageType"] == "GeneralCommand"
    data = msg["Data"]
    assert data["Name"] == "SetVolume"
    assert data["ControllingUserId"] == @user
    # Required and non-null: an absent Arguments discards the message.
    assert data["Arguments"] == %{}
    refute is_nil(data["Arguments"])
  end

  test "general/3 stringifies argument values" do
    data = WsCommand.general("SetVolume", @user, %{"Volume" => 50})["Data"]

    assert data["Arguments"] == %{"Volume" => "50"}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/jellyfin/ws_command_test.exs`
Expected: FAIL — `module Hivefin.Jellyfin.WsCommand is not available`

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Hivefin.Jellyfin.WsCommand do
  @moduledoc """
  Builds Jellyfin remote-control message payloads.

  Every payload here has required (non-defaulted) fields in
  jellyfin-sdk-kotlin, so they are always set: `PlayRequest` needs
  `PlayCommand` + `ControllingUserId`, `PlaystateRequest` needs `Command`, and
  `GeneralCommand` needs `Name` + `ControllingUserId` + `Arguments`.
  """

  alias Hivefin.Jellyfin.WsMessage

  @play_commands ~w(PlayNow PlayNext PlayLast PlayInstantMix PlayShuffle)
  @playstate_commands ~w(Stop Pause Unpause NextTrack PreviousTrack Seek Rewind FastForward PlayPause)

  def play_commands, do: @play_commands
  def playstate_commands, do: @playstate_commands

  @doc "Play envelope. Returns `{:error, :invalid_command}` for an unknown PlayCommand."
  def play(controlling_user_id, params) when is_binary(controlling_user_id) and is_map(params) do
    command = params["PlayCommand"] || "PlayNow"

    if command in @play_commands do
      data =
        params
        |> Map.put("PlayCommand", command)
        |> Map.put("ControllingUserId", controlling_user_id)

      WsMessage.build("Play", data)
    else
      {:error, :invalid_command}
    end
  end

  @doc "Playstate envelope. Returns `{:error, :invalid_command}` for an unknown command."
  def playstate(command, params) when is_binary(command) and is_map(params) do
    if command in @playstate_commands do
      WsMessage.build("Playstate", Map.put(params, "Command", command))
    else
      {:error, :invalid_command}
    end
  end

  @doc "GeneralCommand envelope. `Arguments` is always an object of strings."
  def general(name, controlling_user_id, arguments)
      when is_binary(name) and is_binary(controlling_user_id) and is_map(arguments) do
    data = %{
      "Name" => name,
      "ControllingUserId" => controlling_user_id,
      "Arguments" => Map.new(arguments, fn {k, v} -> {to_string(k), to_string(v)} end)
    }

    WsMessage.build("GeneralCommand", data)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin/jellyfin/ws_command_test.exs`
Expected: PASS (10 tests)

- [ ] **Step 5: Commit**

```bash
mix format lib/hivefin/jellyfin/ws_command.ex test/hivefin/jellyfin/ws_command_test.exs
git add lib/hivefin/jellyfin/ws_command.ex test/hivefin/jellyfin/ws_command_test.exs
git commit -m "feat: Jellyfin remote-control payload builders"
```

---

### Task 9: Command endpoints

**Files:**
- Modify: `lib/hivefin_web/controllers/jellyfin/sessions_controller.ex` — add `play/2`, `playstate/2`, `command/2`, `message/2`.
- Modify: `lib/hivefin_web/router.ex` — add four routes in the same block as the existing `/Sessions` routes (around lines 157-162), **before** the SPA catch-all scope.
- Test: `test/hivefin_web/controllers/jellyfin/sessions_command_test.exs`

**Interfaces:**
- Consumes: `Hivefin.Sessions.push/2`, `Hivefin.Sessions.pids/1`, `Hivefin.Jellyfin.WsCommand.play/2`, `WsCommand.playstate/2`, `WsCommand.general/3`.
- Produces: four controller actions. Responses: **204** delivered, **404** `%{"error" => "no_session"}` when the target has no live socket, **400** `%{"error" => "invalid_command"}` for an unknown enum value.

Capability gating is deliberately **not** implemented here: hivefin advertises `SupportsMediaControl: false` for every session today, so gating would reject every command. Task 10 turns capability reporting on; gating lands with it.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule HivefinWeb.Jellyfin.SessionsCommandTest do
  use HivefinWeb.ConnCase, async: false

  alias Hivefin.Sessions

  setup do
    {:ok, user} =
      Hivefin.Accounts.create_user(%{
        name: "Cmd",
        username: "cmduser",
        password: "password1",
        admin: true
      })

    {:ok, token, _at} =
      Hivefin.Accounts.issue_token(user, %{
        device_id: "phone",
        device_name: "Phone",
        client: "Jellyfin Web",
        client_version: "10.9.0"
      })

    conn =
      build_conn()
      |> put_req_header(
        "x-emby-authorization",
        ~s(MediaBrowser Client="Jellyfin Web", Device="Phone", DeviceId="phone", Version="10.9.0", Token="#{token}")
      )

    {:ok, conn: conn, user: user}
  end

  # Stands in for a TV's socket process.
  defp fake_target(session_id) do
    test = self()

    pid =
      spawn(fn ->
        Sessions.register(session_id, %{user_id: "tv"})
        send(test, :ready)

        receive do
          {:jellyfin_push, msg} -> send(test, {:pushed, msg})
        end

        Process.sleep(:infinity)
      end)

    assert_receive :ready
    pid
  end

  test "POST /Sessions/:id/Playing pushes Play to the target", %{conn: conn, user: user} do
    target = Ecto.UUID.generate()
    fake_target(target)

    conn =
      post(conn, "/Sessions/#{target}/Playing", %{
        "ItemIds" => ["item-1"],
        "PlayCommand" => "PlayNow"
      })

    assert conn.status == 204
    assert_receive {:pushed, msg}
    assert msg["MessageType"] == "Play"
    assert msg["Data"]["PlayCommand"] == "PlayNow"
    assert msg["Data"]["ControllingUserId"] == user.id
    assert msg["Data"]["ItemIds"] == ["item-1"]
  end

  test "POST /Sessions/:id/Playing/Pause pushes Playstate", %{conn: conn} do
    target = Ecto.UUID.generate()
    fake_target(target)

    conn = post(conn, "/Sessions/#{target}/Playing/Pause", %{})

    assert conn.status == 204
    assert_receive {:pushed, msg}
    assert msg["MessageType"] == "Playstate"
    assert msg["Data"]["Command"] == "Pause"
  end

  test "Seek carries SeekPositionTicks", %{conn: conn} do
    target = Ecto.UUID.generate()
    fake_target(target)

    conn = post(conn, "/Sessions/#{target}/Playing/Seek", %{"SeekPositionTicks" => 12_345})

    assert conn.status == 204
    assert_receive {:pushed, msg}
    assert msg["Data"]["Command"] == "Seek"
    assert msg["Data"]["SeekPositionTicks"] == 12_345
  end

  test "POST /Sessions/:id/Command/:command pushes GeneralCommand", %{conn: conn} do
    target = Ecto.UUID.generate()
    fake_target(target)

    conn = post(conn, "/Sessions/#{target}/Command/SetVolume", %{"Volume" => 42})

    assert conn.status == 204
    assert_receive {:pushed, msg}
    assert msg["MessageType"] == "GeneralCommand"
    assert msg["Data"]["Name"] == "SetVolume"
    assert msg["Data"]["Arguments"]["Volume"] == "42"
  end

  test "POST /Sessions/:id/Message pushes a DisplayMessage", %{conn: conn} do
    target = Ecto.UUID.generate()
    fake_target(target)

    conn = post(conn, "/Sessions/#{target}/Message", %{"Header" => "Hi", "Text" => "There"})

    assert conn.status == 204
    assert_receive {:pushed, msg}
    assert msg["Data"]["Name"] == "DisplayMessage"
    assert msg["Data"]["Arguments"]["Header"] == "Hi"
    assert msg["Data"]["Arguments"]["Text"] == "There"
  end

  test "404s when the target has no live socket", %{conn: conn} do
    conn = post(conn, "/Sessions/#{Ecto.UUID.generate()}/Playing", %{"ItemIds" => ["x"]})

    assert json_response(conn, 404)["error"] == "no_session"
  end

  test "400s on an unknown playstate command", %{conn: conn} do
    target = Ecto.UUID.generate()
    fake_target(target)

    conn = post(conn, "/Sessions/#{target}/Playing/Explode", %{})

    assert json_response(conn, 400)["error"] == "invalid_command"
  end

  test "requires authentication" do
    conn = post(build_conn(), "/Sessions/#{Ecto.UUID.generate()}/Playing", %{})

    assert json_response(conn, 401)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin_web/controllers/jellyfin/sessions_command_test.exs`
Expected: FAIL — no route matches `POST /Sessions/:id/Playing`

- [ ] **Step 3a: Add the controller actions**

Add to `lib/hivefin_web/controllers/jellyfin/sessions_controller.ex`, and add
`alias Hivefin.Jellyfin.WsCommand` plus `alias Hivefin.Sessions` at the top:

```elixir
  @doc "`POST /Sessions/:session_id/Playing` — tell a session to play items."
  def play(conn, %{"session_id" => session_id} = params) do
    user = conn.assigns.current_user

    params
    |> Map.drop(["session_id"])
    |> then(&WsCommand.play(user.id, &1))
    |> deliver(conn, session_id)
  end

  @doc "`POST /Sessions/:session_id/Playing/:command` — pause/seek/stop a session."
  def playstate(conn, %{"session_id" => session_id, "command" => command} = params) do
    params
    |> Map.drop(["session_id", "command"])
    |> then(&WsCommand.playstate(command, &1))
    |> deliver(conn, session_id)
  end

  @doc "`POST /Sessions/:session_id/Command/:command` — a GeneralCommand."
  def command(conn, %{"session_id" => session_id, "command" => command} = params) do
    user = conn.assigns.current_user

    command
    |> WsCommand.general(user.id, Map.drop(params, ["session_id", "command"]))
    |> deliver(conn, session_id)
  end

  @doc "`POST /Sessions/:session_id/Message` — display a message on a session."
  def message(conn, %{"session_id" => session_id} = params) do
    user = conn.assigns.current_user
    arguments = Map.take(params, ["Header", "Text", "TimeoutMs"])

    "DisplayMessage"
    |> WsCommand.general(user.id, arguments)
    |> deliver(conn, session_id)
  end

  defp deliver({:error, :invalid_command}, conn, _session_id) do
    conn |> put_status(:bad_request) |> json(%{"error" => "invalid_command"})
  end

  defp deliver(message, conn, session_id) when is_map(message) do
    case Sessions.push(session_id, message) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :no_session} ->
        conn |> put_status(:not_found) |> json(%{"error" => "no_session"})
    end
  end
```

- [ ] **Step 3b: Add the routes**

In `lib/hivefin_web/router.ex`, add these next to the existing `/Sessions`
routes (around lines 157-162):

```elixir
    post "/Sessions/:session_id/Playing", SessionsController, :play
    post "/Sessions/:session_id/Playing/:command", SessionsController, :playstate
    post "/Sessions/:session_id/Command/:command", SessionsController, :command
    post "/Sessions/:session_id/Message", SessionsController, :message
```

These must appear **after** the existing literal `post "/Sessions/Playing"`,
`post "/Sessions/Playing/Progress"`, and `post "/Sessions/Playing/Stopped"`
routes, so those keep matching first — otherwise `:session_id` would swallow
the literal `Playing` segment.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hivefin_web/controllers/jellyfin/sessions_command_test.exs`
Expected: PASS (8 tests)

- [ ] **Step 5: Verify the reporting routes still work**

Run: `mix test test/hivefin_web/controllers/jellyfin/`
Expected: no new failures. Confirm `POST /Sessions/Playing/Progress` still
resolves to `:progress` and not to `:playstate` with `session_id == "Playing"`.

- [ ] **Step 6: Commit**

```bash
mix format lib/hivefin_web/controllers/jellyfin/sessions_controller.ex lib/hivefin_web/router.ex test/hivefin_web/controllers/jellyfin/sessions_command_test.exs
git add lib/hivefin_web/controllers/jellyfin/sessions_controller.ex lib/hivefin_web/router.ex test/hivefin_web/controllers/jellyfin/sessions_command_test.exs
git commit -m "feat: remote-control command endpoints"
```

---

### Task 10: Advertise remote-control capability

**Files:**
- Modify: `lib/hivefin/jellyfin/dto/session.ex` — report control support for sessions holding a live socket.
- Modify: `lib/hivefin_web/controllers/jellyfin/sessions_controller.ex` — gate commands on the target's advertised support.
- Test: `test/hivefin/jellyfin/dto/session_test.exs`, `test/hivefin_web/controllers/jellyfin/sessions_command_test.exs`

**Interfaces:**
- Consumes: `Hivefin.Sessions.pids/1`.
- Produces:
  - `Hivefin.Jellyfin.Dto.Session.from_access_token/2` — second argument `opts :: keyword()` with `:controllable` (boolean, default `false`). When true, `SupportsMediaControl`, `SupportsRemoteControl`, and `Capabilities.SupportsMediaControl` are `true` and `SupportedCommands` lists the advertised commands. `from_access_token/1` keeps working and defaults to `false`.
  - `Hivefin.Jellyfin.Dto.Session.supported_commands/0 :: [String.t()]` — `["DisplayMessage", "SetVolume", "Mute", "Unmute", "ToggleMute"]`.

Only commands the server can actually deliver are advertised. Clients gate their
UI on `SupportedCommands`, so listing an undeliverable command produces a
control that silently does nothing.

- [ ] **Step 1: Write the failing test (append to session_test.exs)**

```elixir
  test "a session with no live socket is not controllable", %{access_token: at} do
    dto = SessionDto.from_access_token(at)

    assert dto["SupportsMediaControl"] == false
    assert dto["SupportsRemoteControl"] == false
    assert dto["SupportedCommands"] == []
  end

  test "a controllable session advertises control support", %{access_token: at} do
    dto = SessionDto.from_access_token(at, controllable: true)

    assert dto["SupportsMediaControl"] == true
    assert dto["SupportsRemoteControl"] == true
    assert dto["Capabilities"]["SupportsMediaControl"] == true
    assert "DisplayMessage" in dto["SupportedCommands"]
  end

  test "controllable sessions still carry every required field", %{access_token: at} do
    dto = SessionDto.from_access_token(at, controllable: true)

    for key <- @required do
      assert Map.has_key?(dto, key), "missing #{key}"
      refute is_nil(dto[key]), "#{key} is null"
    end
  end
```

Append to `sessions_command_test.exs`:

```elixir
  test "403s when the target advertises no media control", %{conn: conn} do
    # A registered session that reports controllable: false.
    target = Ecto.UUID.generate()

    test_pid = self()

    spawn(fn ->
      Sessions.register(target, %{user_id: "tv", controllable: false})
      send(test_pid, :ready)
      Process.sleep(:infinity)
    end)

    assert_receive :ready

    conn = post(conn, "/Sessions/#{target}/Command/SetVolume", %{"Volume" => 10})

    assert json_response(conn, 403)["error"] == "not_controllable"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hivefin/jellyfin/dto/session_test.exs test/hivefin_web/controllers/jellyfin/sessions_command_test.exs`
Expected: FAIL — `from_access_token/2` undefined, and the command returns 204 instead of 403

- [ ] **Step 3a: Make the DTO capability-aware**

In `lib/hivefin/jellyfin/dto/session.ex`:

```elixir
  @supported_commands ~w(DisplayMessage SetVolume Mute Unmute ToggleMute)

  @doc "GeneralCommandType values hivefin can actually deliver."
  def supported_commands, do: @supported_commands

The signature is already `/2` from Task 7. Add two bindings at the top of the
function body:

```elixir
    controllable? = Keyword.get(opts, :controllable, false)
    commands = if controllable?, do: @supported_commands, else: []
```

Then change exactly these four entries in the existing map literal. Before:

```elixir
      "SupportsMediaControl" => false,
      "SupportsRemoteControl" => false,
      "SupportedCommands" => [],
      "Capabilities" => %{
        "PlayableMediaTypes" => ["Video"],
        "SupportedCommands" => [],
        "SupportsMediaControl" => false,
        "SupportsPersistentIdentifier" => true
      }
```

After:

```elixir
      "SupportsMediaControl" => controllable?,
      "SupportsRemoteControl" => controllable?,
      "SupportedCommands" => commands,
      "Capabilities" => %{
        "PlayableMediaTypes" => ["Video"],
        "SupportedCommands" => commands,
        "SupportsMediaControl" => controllable?,
        "SupportsPersistentIdentifier" => true
      }
```

Leave every other key in the map untouched. Note the `@required` defaults map
still carries `"SupportsMediaControl" => false` and `"SupportedCommands" => []`
— that is correct: it only fills keys that are absent or nil, and these are
always present, so the explicit values above win.

- [ ] **Step 3b: Mark registered sockets controllable**

In `lib/hivefin_web/jellyfin_socket.ex`, in `init/1`, include `controllable: true`
in the registered attrs:

```elixir
      Sessions.register(state.session_id, %{
        user_id: state.user_id,
        device_id: state.device_id,
        controllable: true
      })
```

And in `sessions_message/1`, add `controllable:` alongside the `state:` option
introduced in Task 7 — a session is controllable exactly when it holds a live
socket, which is the same condition as having a registry entry:

```elixir
  defp sessions_message(state) do
    live = Map.new(Sessions.list(), &{&1.session_id, &1})

    sessions =
      [user_id: state.user_id]
      |> Accounts.list_access_tokens()
      |> Enum.map(fn at ->
        entry = live[at.id]

        SessionDto.from_access_token(at,
          state: session_state(entry),
          controllable: entry != nil
        )
      end)

    WsMessage.encode("Sessions", sessions)
  end
```

Keep the `session_state/1` helper from Task 7 unchanged.

Apply the same `controllable:` treatment in `SessionsController.index/2` so
`GET /Sessions` agrees with the socket push.

- [ ] **Step 3c: Gate commands**

In `lib/hivefin_web/controllers/jellyfin/sessions_controller.ex`, change
`deliver/3` for map messages to check capability first:

```elixir
  defp deliver(message, conn, session_id) when is_map(message) do
    cond do
      Sessions.pids(session_id) == [] ->
        conn |> put_status(:not_found) |> json(%{"error" => "no_session"})

      not controllable?(session_id) ->
        conn |> put_status(:forbidden) |> json(%{"error" => "not_controllable"})

      true ->
        Sessions.push(session_id, message)
        send_resp(conn, :no_content, "")
    end
  end

  defp controllable?(session_id) do
    Sessions.list()
    |> Enum.any?(&(&1.session_id == session_id and Map.get(&1, :controllable, false)))
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/hivefin/jellyfin/dto/session_test.exs test/hivefin_web/controllers/jellyfin/sessions_command_test.exs`
Expected: PASS (7 + 9 tests)

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: 8 pre-existing failures, no new ones.

- [ ] **Step 6: Commit and deploy Stage 3**

```bash
mix format lib/hivefin/jellyfin/dto/session.ex lib/hivefin_web/jellyfin_socket.ex lib/hivefin_web/controllers/jellyfin/sessions_controller.ex test/hivefin/jellyfin/dto/session_test.exs test/hivefin_web/controllers/jellyfin/sessions_command_test.exs
git add -A
git commit -m "feat: advertise and gate remote-control capability"
git push origin main
ssh root@192.168.1.176 'cd /root/apps/hivefin && git pull --ff-only'
ssh root@192.168.1.176 'cd /root/apps/hivefin && docker compose up -d --build'
```

Verify on devices: from the web client or phone, pick the TV as a playback
target and start a movie. Confirm it starts on the TV, and that pause and
volume from the controlling client reach it.

---

## Verification summary

| Stage | Server-side check | Device check |
|-------|------------------|--------------|
| 1 | `/socket` upgrades with a token, 401 without | `GET /socket` count in logs drops from ~69 to 1-2 per client |
| 2 | every `SessionInfoDto` carries 9 required fields | a second client sees the first's now-playing state |
| 3 | commands 204 / 404 / 400 / 403 correctly | "play on device" starts playback on the TV; pause and volume reach it |

Known pre-existing failures that must stay at 8 and are out of scope: 4
`AndroidTvGaps` (ID format), 2 `System/Info` (version drift), 2 compat
(`Path` assertion).
