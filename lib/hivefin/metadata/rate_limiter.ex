defmodule Hivefin.Metadata.RateLimiter do
  @moduledoc """
  Simple token-bucket rate limiter for metadata provider HTTP calls.

  Default capacity / refill rate: `config :hivefin, :tmdb_rate_limit_per_sec` (4).
  """

  use GenServer

  @name __MODULE__

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Blocks until a request token is available, then consumes one.

  Returns `:ok` on success, or `:error` if the call exits (timeout / death).
  When the limiter process is not started (`whereis` nil), returns `:ok` (no-op).
  """
  @spec checkout(GenServer.server()) :: :ok | :error
  def checkout(server \\ @name) do
    case Process.whereis(server) do
      nil ->
        :ok

      _pid ->
        try do
          GenServer.call(server, :checkout, 30_000)
        catch
          # Fail-closed: do not allow HTTP when the limiter cannot grant a token
          :exit, _reason -> :error
        end
    end
  end

  @doc """
  Updates the refill rate at runtime (admin settings).
  """
  def set_rate(rate, server \\ @name) when is_integer(rate) and rate > 0 do
    case Process.whereis(server) do
      nil -> :ok
      _pid -> GenServer.cast(server, {:set_rate, rate})
    end
  end

  @impl true
  def init(opts) do
    rate =
      Keyword.get(opts, :rate) ||
        Application.get_env(:hivefin, :tmdb_rate_limit_per_sec, 4)

    rate = if is_integer(rate) and rate > 0, do: rate, else: 4

    state = %{
      tokens: rate,
      rate: rate,
      last_refill: System.monotonic_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:set_rate, rate}, state) when is_integer(rate) and rate > 0 do
    {:noreply, %{state | rate: rate, tokens: min(state.tokens, rate)}}
  end

  @impl true
  def handle_call(:checkout, from, state) do
    state = refill(state)

    if state.tokens >= 1 do
      {:reply, :ok, %{state | tokens: state.tokens - 1}}
    else
      # Wait until next token (approx 1000/rate ms)
      wait_ms = max(div(1000, state.rate), 1)
      Process.send_after(self(), {:grant, from}, wait_ms)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:grant, from}, state) do
    state = refill(state)

    if state.tokens >= 1 do
      GenServer.reply(from, :ok)
      {:noreply, %{state | tokens: state.tokens - 1}}
    else
      wait_ms = max(div(1000, state.rate), 1)
      Process.send_after(self(), {:grant, from}, wait_ms)
      {:noreply, state}
    end
  end

  defp refill(%{tokens: tokens, rate: rate, last_refill: last} = state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - last
    add = div(elapsed * rate, 1000)

    if add > 0 do
      %{state | tokens: min(rate, tokens + add), last_refill: now}
    else
      state
    end
  end
end
