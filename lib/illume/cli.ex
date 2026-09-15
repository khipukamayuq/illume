defmodule Illume.CLI do
  @moduledoc """
  Escript entry point. `mix escript.build` starts the `:illume`
  application (and with it `Illume.ToolSupervisor`) before calling
  `main/1`.

  By default, tools run as direct in-process calls. Pass `--mcp` to instead
  route the four MCP-backed tools through the official filesystem and git
  reference servers via `anubis_mcp`; `grep_content` always runs locally
  either way. `--mcp` requires `npx` and `uvx` on PATH and network access on
  first run.

  Pass `--serve <target_dir>` instead of a question to run Illume itself as
  an MCP server (`Illume.MCPServer`) over stdio, exposing the same five
  read-only tools to an external MCP client. This is a distinct axis from
  `--mcp` (that flag is about which backend *this* process's own agent
  loop uses; `--serve` skips the agent loop and question entirely). No
  `ANTHROPIC_API_KEY` is required for `--serve` — no model is called.
  `target_dir` is fixed for the process's whole lifetime via
  `Application.put_env/3` (see DECISIONS.md's "`target_dir` passed via
  `Application.put_env/3`" note under "MCP server (Component 1)").
  `--serve` also redirects the default `:logger` handler to stderr before
  starting the server: `anubis_mcp`'s stdio transport reads this
  process's raw stdout as newline-delimited JSON-RPC, and Elixir's
  default Logger handler writes to that same stdout — any log line (even
  a debug one from `anubis_mcp` itself) corrupts the protocol stream.
  Found live by the end-to-end smoke test, not by inspection (see
  DECISIONS.md's "`anubis_mcp`'s own stdio Logger-redirect is a no-op"
  note under "MCP server (Component 1)"). `serve/1` also monitors the
  started server and exits (rather than blocking forever) once it dies —
  see `await_server_exit/1` and DECISIONS.md's "Stdio EOF restart-storm"
  note (same section) for why that's needed.

  `answer/3` guarantees `Illume.Tools.MCP.stop_clients/0` runs after the
  agent finishes, on both success and error, via `try/after`. It does
  not guarantee cleanup on Ctrl-C: Elixir cannot trap `:sigint` (see
  DECISIONS.md's "MCP subprocess cleanup" note under "Hardening pass 1"),
  so an interrupted `--mcp` run leaves its spawned `npx`/`uvx`
  subprocesses running until the VM exits or is force-killed.

  The same `:sigint` limitation applies to `--serve`, though with a
  different consequence: `--serve` spawns no subprocess of its own (it
  *is* the child of whatever MCP client started it), so there's nothing
  to leak — but a direct Ctrl-C also bypasses `await_server_exit/1`'s
  graceful-exit monitor, the same as it bypasses `stop_clients/0` above.
  In practice this rarely matters: a real MCP client disconnects by
  closing the pipe (stdin EOF), which `--serve` already handles (see the
  "Stdio EOF restart-storm" mitigation, same section as above) — SIGINT
  only comes up if a human runs `--serve` directly at a terminal and
  interrupts it themselves.

  Argument parsing and validation (`parse_args/1`, `validate/1`) are pure
  — no I/O, no `System.halt/1` — so they're testable directly; `main/1`
  is the thin I/O boundary around them.
  """

  alias Illume.Tools.MCP

  @doc "Parse escript argv into a target dir, question, and tool backend, or a `--serve` request."
  @spec parse_args([String.t()]) ::
          {:ok, Path.t(), String.t(), Illume.Tools.backend()} | {:serve, Path.t()} | :error
  def parse_args(["--mcp", target_dir, question]), do: {:ok, target_dir, question, :mcp}
  def parse_args(["--serve", target_dir]), do: {:serve, target_dir}
  def parse_args([target_dir, question]), do: {:ok, target_dir, question, :direct}
  def parse_args(_argv), do: :error

  @doc "Validate that `target_dir` exists and an API key is available."
  @spec validate(Path.t()) :: :ok | {:error, String.t()}
  def validate(target_dir) do
    cond do
      not File.dir?(target_dir) ->
        {:error, "#{target_dir} is not a directory"}

      is_nil(System.get_env("ANTHROPIC_API_KEY")) ->
        {:error, "ANTHROPIC_API_KEY is not set"}

      true ->
        :ok
    end
  end

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case parse_args(argv) do
      {:ok, target_dir, question, backend} ->
        case validate(target_dir) do
          :ok -> answer(target_dir, question, backend)
          {:error, message} -> fail(message)
        end

      {:serve, target_dir} ->
        case validate_target_dir(target_dir) do
          :ok -> serve(target_dir)
          {:error, message} -> fail(message)
        end

      :error ->
        fail("usage: illume [--mcp] <target_dir> \"<question>\" | illume --serve <target_dir>")
    end
  end

  @spec answer(Path.t(), String.t(), Illume.Tools.backend()) :: no_return()
  defp answer(target_dir, question, backend) do
    case start_backend(backend, target_dir) do
      :ok ->
        result =
          try do
            run_agent(target_dir, question, backend)
          after
            stop_backend(backend)
          end

        case result do
          {:ok, text} -> IO.puts(text)
          {:error, reason} -> fail("agent error: #{inspect(reason)}")
        end

      {:error, reason} ->
        fail("failed to start MCP tool servers: #{inspect(reason)}")
    end
  end

  @spec run_agent(Path.t(), String.t(), Illume.Tools.backend()) ::
          {:ok, String.t()} | {:error, term()}
  defp run_agent(target_dir, question, backend), do: Illume.QA.ask(target_dir, question, backend)

  @spec validate_target_dir(Path.t()) :: :ok | {:error, String.t()}
  defp validate_target_dir(target_dir) do
    if File.dir?(target_dir), do: :ok, else: {:error, "#{target_dir} is not a directory"}
  end

  @spec serve(Path.t()) :: no_return()
  defp serve(target_dir) do
    redirect_logger_to_stderr()
    Application.put_env(:illume, :mcp_server_target_dir, target_dir)

    case DynamicSupervisor.start_child(
           Illume.MCPServerSupervisor,
           {Illume.MCPServer, transport: :stdio}
         ) do
      {:ok, pid} -> await_server_exit(pid)
      {:error, reason} -> fail("failed to start MCP server: #{inspect(reason)}")
    end
  end

  # `Anubis.Server.Supervisor`'s stdio transport child is `:permanent` under
  # a `:one_for_all` strategy, with no supported option to change either —
  # a normal client disconnect (stdin EOF) restarts the whole session tree,
  # which sees the same permanent EOF again immediately and typically
  # exhausts the default restart intensity within milliseconds, crashing
  # this supervisor (confirmed against anubis_mcp 2.0.0, the latest
  # release, and its own issue tracker; see DECISIONS.md's "Stdio EOF
  # restart-storm" note under "MCP server (Component 1)").
  # `main/1`'s process has no link to that tree, so without this monitor it
  # would sleep forever as a zombie once the server dies; this at least
  # exits with a visible error instead.
  @spec await_server_exit(pid()) :: no_return()
  defp await_server_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :shutdown] ->
        System.halt(0)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        fail("MCP server exited: #{inspect(reason)}")
    end
  end

  # `:logger`'s `:default` handler can't change its `:type` (device) on a
  # running handler — `logger_std_h` rejects that as an
  # `:illegal_config_change` — so this removes and re-adds it, keeping every
  # other key (formatter, filters, level) exactly as Elixir's own bootstrap
  # set them and swapping only the device.
  @spec redirect_logger_to_stderr() :: :ok
  defp redirect_logger_to_stderr do
    {:ok, handler} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(
        :default,
        handler.module,
        handler
        |> Map.update!(:config, &Map.put(&1, :type, :standard_error))
        |> Map.take([:config, :level, :filter_default, :filters, :formatter])
      )

    :ok
  end

  @spec start_backend(Illume.Tools.backend(), Path.t()) :: :ok | {:error, term()}
  defp start_backend(:direct, _target_dir), do: :ok
  defp start_backend(:mcp, target_dir), do: MCP.start_clients(target_dir)

  @spec stop_backend(Illume.Tools.backend()) :: :ok
  defp stop_backend(:direct), do: :ok
  defp stop_backend(:mcp), do: MCP.stop_clients()

  @spec fail(String.t()) :: no_return()
  defp fail(message) do
    IO.puts(:stderr, "Error: #{message}")
    System.halt(1)
  end
end
