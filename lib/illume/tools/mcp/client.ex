defmodule Illume.Tools.MCP.Client do
  @moduledoc """
  Behaviour around the subset of `Anubis.Client` that `Illume.Tools.MCP`
  needs, so tests can inject a Mox double instead of spawning real
  `npx`/`uvx` MCP server processes.
  """

  @callback call_tool(GenServer.server(), String.t(), map()) ::
              {:ok, Anubis.MCP.Response.t()} | {:error, Anubis.MCP.Error.t()}
  @callback await_ready(GenServer.server(), keyword()) :: :ok | {:error, term()}
end
