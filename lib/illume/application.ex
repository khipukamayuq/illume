defmodule Illume.Application do
  @moduledoc false

  use Application

  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Illume.ToolSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, max_children: 20, name: Illume.AgentSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Illume.MCPSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Illume.MCPServerSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Illume.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
