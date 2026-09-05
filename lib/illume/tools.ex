defmodule Illume.Tools do
  @moduledoc """
  The allow-list and dispatch table for every tool the model may call.

  This is the actual enforcement of "read-only": whatever tool names are
  surfaced to the model must appear in `@allowed` here, and `dispatch/4`
  re-checks the allow-list itself rather than trusting the caller — even if
  an MCP server offers write/delete/commit tools, they can never be reached
  through this module.

  Beyond the allow-list, `dispatch/4` also validates `read_file`'s path
  confinement and `git_show`'s revision before running anything, uniformly
  regardless of which `backend()` ends up handling the call — an MCP-backed
  tool must never be less strict than its direct-call counterpart, even
  when the underlying reference server happens to enforce the same thing
  itself. The backend is an explicit argument (threaded from `Illume.CLI`
  through `Illume.Agent`'s state), not process-global mutable
  configuration — the exact same tool call must behave identically no
  matter how many agents with different backends happen to be running.

  `grep_content` has no MCP equivalent (neither reference server exposes
  content search), so it always runs locally regardless of backend.
  """

  alias Illume.Tools.{Filesystem, Git, Grep, MCP, PathConfinement}

  @allowed ~w(read_file search_files grep_content git_log git_show)

  @type backend :: :direct | :mcp

  @doc "Whether `name` is on the allow-list."
  @spec allowed?(String.t()) :: boolean()
  def allowed?(name), do: name in @allowed

  @doc """
  Run an allowed tool by name against the given `backend` (`:direct` by
  default). Returns `{:error, :not_allowed}` without invoking anything if
  `name` is not on the allow-list.
  """
  @spec dispatch(String.t(), map(), Path.t(), backend()) :: {:ok, term()} | {:error, term()}
  def dispatch(name, input, target_dir, backend \\ :direct) do
    cond do
      not allowed?(name) ->
        {:error, :not_allowed}

      (validation_error = validate_input(name, input, target_dir)) != :ok ->
        validation_error

      true ->
        run(name, input, target_dir, backend)
    end
  end

  @spec validate_input(String.t(), map(), Path.t()) :: :ok | {:error, String.t()}
  defp validate_input("read_file", %{"path" => path}, target_dir) do
    case PathConfinement.confine(target_dir, path) do
      {:ok, _full_path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_input("git_show", %{"revision" => revision}, _target_dir) do
    if String.starts_with?(revision, "-") do
      {:error, "invalid revision: #{revision}"}
    else
      :ok
    end
  end

  defp validate_input(_name, _input, _target_dir), do: :ok

  @spec run(String.t(), map(), Path.t(), backend()) :: {:ok, term()} | {:error, term()}
  defp run("grep_content", input, target_dir, _backend), do: Grep.grep_content(target_dir, input)
  defp run(name, input, target_dir, :direct), do: run_direct(name, input, target_dir)
  defp run(name, input, target_dir, :mcp), do: run_mcp(name, input, target_dir)

  @spec run_direct(String.t(), map(), Path.t()) :: {:ok, term()} | {:error, term()}
  defp run_direct("read_file", input, target_dir), do: Filesystem.read_file(target_dir, input)

  defp run_direct("search_files", input, target_dir),
    do: Filesystem.search_files(target_dir, input)

  defp run_direct("git_log", input, target_dir), do: Git.git_log(target_dir, input)
  defp run_direct("git_show", input, target_dir), do: Git.git_show(target_dir, input)

  @spec run_mcp(String.t(), map(), Path.t()) :: {:ok, term()} | {:error, term()}
  defp run_mcp("read_file", input, target_dir), do: MCP.read_file(target_dir, input)
  defp run_mcp("search_files", input, target_dir), do: MCP.search_files(target_dir, input)
  defp run_mcp("git_log", input, target_dir), do: MCP.git_log(target_dir, input)
  defp run_mcp("git_show", input, target_dir), do: MCP.git_show(target_dir, input)

  @doc "Tool schemas to pass as `tools:` on the Messages request."
  @spec specs() :: [map()]
  def specs do
    [
      ReqAnthropic.Tools.custom(
        name: "read_file",
        description:
          "Read the full contents of a file, given a path relative to the codebase root.",
        input_schema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path relative to the codebase root"}
          },
          required: ["path"]
        }
      ),
      ReqAnthropic.Tools.custom(
        name: "search_files",
        description:
          "Find files whose NAME matches a glob pattern (e.g. \"*_test.exs\"), recursively. " <>
            "Does not search file contents — use grep_content for that.",
        input_schema: %{
          type: "object",
          properties: %{pattern: %{type: "string", description: "Glob pattern, e.g. \"*.ex\""}},
          required: ["pattern"]
        }
      ),
      ReqAnthropic.Tools.custom(
        name: "grep_content",
        description:
          "Search file contents for a fixed (non-regex) string, recursively. " <>
            "Use this to find where a symbol, function, or string is used.",
        input_schema: %{
          type: "object",
          properties: %{
            pattern: %{type: "string", description: "Fixed string to search for"},
            path: %{type: "string", description: "Optional subdirectory to scope the search to"}
          },
          required: ["pattern"]
        }
      ),
      ReqAnthropic.Tools.custom(
        name: "git_log",
        description: "Show recent commit history (hash, date, author, subject).",
        input_schema: %{
          type: "object",
          properties: %{
            max_count: %{type: "integer", description: "Number of commits to show (default 20)"}
          },
          required: []
        }
      ),
      ReqAnthropic.Tools.custom(
        name: "git_show",
        description:
          "Show a single commit's message and full diff, given a revision (hash, tag, or ref).",
        input_schema: %{
          type: "object",
          properties: %{revision: %{type: "string", description: "Commit hash, tag, or ref"}},
          required: ["revision"]
        }
      )
    ]
  end
end
