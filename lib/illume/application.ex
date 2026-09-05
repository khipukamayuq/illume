defmodule Illume.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Illume.ToolSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Illume.AgentSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Illume.MCPSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Illume.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
