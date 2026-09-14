defmodule Illume.Tools.MCP do
  @moduledoc """
  The four MCP-backed tools (read_file, search_files, git_log, git_show)
  dispatched to the official filesystem and git reference servers via
  `anubis_mcp`. `grep_content` has no MCP equivalent and is never routed
  here — see `Illume.Tools`.

  Client processes are started per-CLI-invocation (the target directory is
  only known at runtime) under `Illume.MCPSupervisor`, not declared
  statically in `Illume.Application`.

  The filesystem and git clients are given distinct `client_info["name"]`
  values (`start_clients/1`) rather than sharing one: `Anubis.Client.Cache`
  keys its (per-process, `:private`) ETS tool-validator table by that name
  alone, not by client process, so two clients sharing a name collide on
  the same table and crash with an ETS "insufficient access rights" error
  on any tool result that carries `structuredContent` — which includes
  every `isError` result.

  All calls to `Anubis.Client` go through `client_adapter/0`
  (`Application.get_env(:illume, :mcp_client, Illume.Tools.MCP.AnubisClient)`)
  rather than calling `Anubis.Client` directly, so tests can inject a Mox
  double instead of spawning real `npx`/`uvx` server processes.

  `search_files/2`'s matches are re-filtered through
  `Illume.Tools.PathConfinement.within?/2` before being returned, the same
  way `Illume.Tools.Filesystem.search_files/2` re-filters its own matches
  for the `:direct` backend — this tool is never handed input validation
  by `Illume.Tools.validate_input/3`, so the confinement guarantee has to
  live here instead. A match resolving outside the target directory would
  mean the reference server's own confinement failed; that's reported via
  `[:illume, :mcp, :confinement_violation]` rather than silently dropped
  with no trace. Matches are also required to already be absolute
  (`within_confinement?/2` rejects anything else as a violation) — the
  reference server has only ever been observed to return absolute paths,
  but `PathConfinement.within?/2` itself would otherwise resolve a
  relative one against this VM's own working directory, not `target_dir`,
  which is the wrong base entirely for an external server's response.

  `confine_matches/2` distinguishes the server's own "no matches" from
  confinement dropping every match it returned, so the model isn't told
  "there is no such file" when out-of-bounds matches were actually found
  and suppressed. The server's matches arrive as a single newline-joined
  string rather than a real list, so a filename containing a literal
  newline is inherently ambiguous at this transport boundary — the
  `structuredContent` field carries the identical joined string, not an
  array, so it offers no way around this. Accepted as-is: not an escape
  risk (such a match still can't resolve outside `target_dir`), and
  exceptionally unlikely for the Elixir codebases this tool targets.
  """

  alias Illume.Tools.PathConfinement

  @filesystem_client Illume.MCP.FilesystemClient
  @git_client Illume.MCP.GitClient
  @ready_timeout 15_000

  @doc """
  Start both reference-server clients scoped to `target_dir` and wait for
  their MCP handshake to complete.
  """
  @spec start_clients(Path.t()) :: :ok | {:error, term()}
  def start_clients(target_dir) do
    with {:ok, _} <-
           DynamicSupervisor.start_child(Illume.MCPSupervisor, filesystem_spec(target_dir)),
         {:ok, _} <- DynamicSupervisor.start_child(Illume.MCPSupervisor, git_spec(target_dir)),
         :ok <- client_adapter().await_ready(@filesystem_client, timeout: @ready_timeout),
         :ok <- client_adapter().await_ready(@git_client, timeout: @ready_timeout) do
      :ok
    else
      error ->
        stop_clients()
        error
    end
  end

  @doc "Stop every MCP client process currently running under `Illume.MCPSupervisor`."
  @spec stop_clients() :: :ok
  def stop_clients do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(Illume.MCPSupervisor) do
      DynamicSupervisor.terminate_child(Illume.MCPSupervisor, pid)
    end

    :ok
  end

  @spec filesystem_spec(Path.t()) :: {module(), keyword()}
  defp filesystem_spec(target_dir) do
    {Anubis.Client,
     name: @filesystem_client,
     transport:
       {:stdio,
        command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", target_dir]},
     client_info: %{"name" => "illume-filesystem", "version" => "0.1.0"},
     capabilities: %{}}
  end

  @spec git_spec(Path.t()) :: {module(), keyword()}
  defp git_spec(target_dir) do
    {Anubis.Client,
     name: @git_client,
     transport: {:stdio, command: "uvx", args: ["mcp-server-git", "--repository", target_dir]},
     client_info: %{"name" => "illume-git", "version" => "0.1.0"},
     capabilities: %{}}
  end

  @spec read_file(Path.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def read_file(_target_dir, %{"path" => path}) do
    call(@filesystem_client, "read_text_file", %{"path" => path})
  end

  @spec search_files(Path.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def search_files(target_dir, %{"pattern" => pattern}) do
    case call(@filesystem_client, "search_files", %{
           "path" => target_dir,
           "pattern" => pattern,
           "excludePatterns" => []
         }) do
      {:ok, text} -> {:ok, confine_matches(text, target_dir)}
      error -> error
    end
  end

  @spec git_log(Path.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def git_log(target_dir, input) do
    args = %{"repo_path" => target_dir}
    args = if mc = input["max_count"], do: Map.put(args, "max_count", mc), else: args
    call(@git_client, "git_log", args)
  end

  @spec git_show(Path.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def git_show(target_dir, %{"revision" => revision}) do
    call(@git_client, "git_show", %{"repo_path" => target_dir, "revision" => revision})
  end

  @spec call(GenServer.server(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  defp call(client, tool_name, arguments) do
    case client_adapter().call_tool(client, tool_name, arguments) do
      {:ok, %{is_error: true, result: result}} -> {:error, extract_text(result)}
      {:ok, %{result: result}} -> {:ok, extract_text(result)}
      {:error, error} -> {:error, format_error(error)}
    end
  end

  @spec client_adapter() :: module()
  defp client_adapter,
    do: Application.get_env(:illume, :mcp_client, Illume.Tools.MCP.AnubisClient)

  @no_matches_text "No matches found"
  @no_matches_within_target_text "No matches found within the target directory."

  @spec confine_matches(String.t(), Path.t()) :: String.t()
  defp confine_matches(text, target_dir) do
    if String.trim(text) == @no_matches_text do
      text
    else
      root = Path.expand(target_dir)
      lines = String.split(text, "\n", trim: true)
      {kept, dropped} = Enum.split_with(lines, &within_confinement?(&1, root))
      join_matches(kept, dropped)
    end
  end

  @spec join_matches([String.t()], [String.t()]) :: String.t()
  defp join_matches([], []), do: @no_matches_text
  defp join_matches([], _dropped), do: @no_matches_within_target_text
  defp join_matches(lines, _dropped), do: Enum.join(lines, "\n")

  @spec within_confinement?(String.t(), Path.t()) :: boolean()
  defp within_confinement?(path, root) do
    if Path.type(path) == :absolute and PathConfinement.within?(path, root) do
      true
    else
      reject_out_of_bounds(path, root)
    end
  end

  @spec reject_out_of_bounds(String.t(), Path.t()) :: false
  defp reject_out_of_bounds(path, root) do
    :telemetry.execute(
      [:illume, :mcp, :confinement_violation],
      %{system_time: System.system_time()},
      %{tool: "search_files", path: path, root: root}
    )

    false
  end

  @spec extract_text(term()) :: String.t()
  defp extract_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "text"}, &1))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp extract_text(other), do: inspect(other)

  @spec format_error(term()) :: String.t()
  defp format_error(%Anubis.MCP.Error{reason: reason, message: message}),
    do: "#{reason}: #{message}"

  defp format_error(other), do: inspect(other)
end
