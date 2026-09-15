defmodule Illume.MCPServer do
  @moduledoc """
  Exposes `Illume.Tools`' five read-only tools over MCP (`use Anubis.Server`).

  Started via `{Illume.MCPServer, transport: :stdio}` under
  `Illume.MCPServerSupervisor` when the CLI is invoked with `--serve` (see
  `Illume.CLI`) — not part of `Illume.Application`'s default children.
  `target_dir` is read once from `Application.fetch_env!/2` in `init/2`
  rather than threaded through supervisor start opts, which `anubis_mcp`
  has no channel for (see DECISIONS.md entry 50).

  `init/2` builds `%Anubis.Server.Component.Tool{}` structs directly and
  puts them in `frame.tools`, rather than calling `Frame.register_tool/3`
  (which expects a Peri-DSL schema and would mangle `Tools.specs()`'s raw
  JSON Schema maps) or the `component`/`schema do...end` macros (same
  problem, at compile time). Every tool sets `validate_input: fn params ->
  {:ok, params} end` — leaving it `nil` makes `anubis_mcp` silently
  replace real client arguments with `%{}` before dispatch ever sees them.
  See DECISIONS.md entry 49.

  `to_content_string/1`'s catch-all `inspect/1` clause is only ever
  reached today because every tool in `Illume.Tools.specs()` returns a
  string or a list of strings; a future tool returning something else
  would silently change what the MCP client sees instead of erroring.
  """

  use Anubis.Server, name: "illume", version: "0.1.0", capabilities: [:tools]

  alias Anubis.Server.Component.Tool
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  @impl true
  @spec init(map(), Frame.t()) :: {:ok, Frame.t()}
  def init(_client_info, frame) do
    target_dir = Application.fetch_env!(:illume, :mcp_server_target_dir)
    frame = Frame.assign(frame, :target_dir, target_dir)
    {:ok, Enum.reduce(Illume.Tools.specs(), frame, &register_illume_tool/2)}
  end

  @impl true
  @spec handle_tool_call(String.t(), map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
  def handle_tool_call(name, params, frame) do
    case Illume.Tools.dispatch(name, params, frame.assigns.target_dir, :direct) do
      {:ok, result} ->
        {:reply, Response.tool() |> Response.text(to_content_string(result)), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error(to_content_string(reason)), frame}
    end
  end

  @spec register_illume_tool(map(), Frame.t()) :: Frame.t()
  defp register_illume_tool(%{name: name, description: description, input_schema: schema}, frame) do
    tool = %Tool{
      name: name,
      description: description,
      input_schema: schema,
      handler: nil,
      validate_input: fn params -> {:ok, params} end
    }

    %{frame | tools: Map.put(frame.tools, name, tool)}
  end

  @doc false
  @spec to_content_string(term()) :: String.t()
  def to_content_string(result) when is_binary(result), do: result
  def to_content_string(result) when is_list(result), do: Enum.join(result, "\n")
  def to_content_string(result), do: inspect(result)
end
