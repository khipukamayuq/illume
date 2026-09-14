defmodule Illume.Tools.MCP.AnubisClient do
  @moduledoc "Real `Illume.Tools.MCP.Client` implementation, delegating to `Anubis.Client`."

  @behaviour Illume.Tools.MCP.Client

  @spec call_tool(GenServer.server(), String.t(), map()) ::
          {:ok, Anubis.MCP.Response.t()} | {:error, Anubis.MCP.Error.t()}
  @impl true
  def call_tool(client, tool_name, arguments),
    do: Anubis.Client.call_tool(client, tool_name, arguments)

  @spec await_ready(GenServer.server(), keyword()) :: :ok | {:error, term()}
  @impl true
  def await_ready(client, opts), do: Anubis.Client.await_ready(client, opts)
end
