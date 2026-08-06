defmodule Hivefin.Playback.FFmpeg.Runner do
  @moduledoc """
  Thin Port wrapper around the configured `ffmpeg` binary.

  Only accepts argv lists produced by `Hivefin.Playback.FFmpeg.Args` (or
  other server-side builders). Does not interpolate client-supplied filter
  strings.
  """

  require Logger

  @type port_ref :: port()

  @doc """
  Opens an FFmpeg process with the given argument list (excluding the binary).

  ## Options
  - `:ffmpeg_path` — override configured path
  - `:cd` — working directory
  - `:env` — extra environment as `[{charlist, charlist}]` (Port format)
  """
  @spec open([String.t()], keyword()) :: {:ok, port_ref()} | {:error, term()}
  def open(args, opts \\ []) when is_list(args) do
    ffmpeg = Keyword.get(opts, :ffmpeg_path) || ffmpeg_path()

    unless is_binary(ffmpeg) and ffmpeg != "" do
      throw({:error, :ffmpeg_missing})
    end

    # Validate executable exists when path is absolute-ish; relative names rely on PATH via spawn.
    if String.contains?(ffmpeg, "/") and not File.regular?(ffmpeg) do
      {:error, :ffmpeg_missing}
    else
      exec = find_executable(ffmpeg)

      port_opts = [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        {:args, args},
        {:parallelism, true}
      ]

      port_opts =
        port_opts
        |> maybe_put(:cd, Keyword.get(opts, :cd) && to_charlist(Keyword.get(opts, :cd)))
        |> maybe_put(:env, Keyword.get(opts, :env))

      try do
        port = Port.open({:spawn_executable, to_charlist(exec)}, port_opts)
        {:ok, port}
      rescue
        e ->
          Logger.warning("Failed to open ffmpeg port: #{inspect(e)}")
          {:error, {:port_open_failed, e}}
      end
    end
  catch
    {:error, reason} -> {:error, reason}
  end

  @doc """
  Closes the port (sends EOF to stdin / stops reading). Prefer killing via
  OS signal from the session for active encodes.
  """
  @spec close(port_ref()) :: :ok
  def close(port) when is_port(port) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Returns the OS pid of the port's external process, if available.
  """
  @spec os_pid(port_ref()) :: non_neg_integer() | nil
  def os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  @doc """
  Sends SIGTERM then SIGKILL to the OS process if still alive.
  """
  @spec kill(port_ref() | non_neg_integer() | nil) :: :ok
  def kill(nil), do: :ok

  def kill(port) when is_port(port) do
    pid = os_pid(port)
    close(port)
    kill(pid)
  end

  def kill(os_pid) when is_integer(os_pid) and os_pid > 0 do
    _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    Process.sleep(50)

    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} ->
        _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def kill(_), do: :ok

  defp ffmpeg_path do
    Application.get_env(:hivefin, :ffmpeg_path) ||
      System.find_executable("ffmpeg") ||
      "ffmpeg"
  end

  defp find_executable(path) do
    if String.contains?(path, "/") do
      path
    else
      System.find_executable(path) || path
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
