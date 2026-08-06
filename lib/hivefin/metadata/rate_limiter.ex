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

  Returns `:ok`. Safe to call when the limiter is not started (no-op).
  """
  def checkout(server \\ @name) do
    case Process.whereis(server) do
      nil ->
        :ok

      _pid ->
        try do
          GenServer.call(server, :checkout, 30_000)
        catch
          # Timeout or server death must not crash metadata Tasks
          :exit, _reason -> :ok
        end
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
