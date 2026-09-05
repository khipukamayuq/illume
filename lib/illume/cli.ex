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

  Argument parsing and validation (`parse_args/1`, `validate/1`) are pure
  — no I/O, no `System.halt/1` — so they're testable directly; `main/1`
  is the thin I/O boundary around them.
  """

  @doc "Parse escript argv into a target dir, question, and tool backend."
  @spec parse_args([String.t()]) :: {:ok, Path.t(), String.t(), Illume.Tools.backend()} | :error
  def parse_args(["--mcp", target_dir, question]), do: {:ok, target_dir, question, :mcp}
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

      :error ->
        fail("usage: illume [--mcp] <target_dir> \"<question>\"")
    end
  end

  @spec answer(Path.t(), String.t(), Illume.Tools.backend()) :: no_return()
  defp answer(target_dir, question, backend) do
    case start_backend(backend, target_dir) do
      :ok ->
        child_spec =
          Supervisor.child_spec(
            {Illume.Agent, target_dir: target_dir, tool_backend: backend},
            restart: :temporary
          )

        {:ok, pid} = DynamicSupervisor.start_child(Illume.AgentSupervisor, child_spec)

        case Illume.Agent.ask(pid, question) do
          {:ok, text} -> IO.puts(text)
          {:error, reason} -> fail("agent error: #{inspect(reason)}")
        end

      {:error, reason} ->
        fail("failed to start MCP tool servers: #{inspect(reason)}")
    end
  end

  @spec start_backend(Illume.Tools.backend(), Path.t()) :: :ok | {:error, term()}
  defp start_backend(:direct, _target_dir), do: :ok
  defp start_backend(:mcp, target_dir), do: Illume.Tools.MCP.start_clients(target_dir)

  @spec fail(String.t()) :: no_return()
  defp fail(message) do
    IO.puts(:stderr, "Error: #{message}")
    System.halt(1)
  end
end
