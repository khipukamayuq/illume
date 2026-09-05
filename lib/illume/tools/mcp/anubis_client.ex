defmodule Illume.Tools.MCP.AnubisClient do
  @moduledoc "Real `Illume.Tools.MCP.Client` implementation, delegating to `Anubis.Client`."

  @behaviour Illume.Tools.MCP.Client

  @impl true
  def call_tool(client, tool_name, arguments),
    do: Anubis.Client.call_tool(client, tool_name, arguments)

  @impl true
  def await_ready(client, opts), do: Anubis.Client.await_ready(client, opts)
end
