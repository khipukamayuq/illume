defmodule Illume.Tools.Runner do
  @moduledoc """
  Runs an arbitrary 0-arity function under `Illume.ToolSupervisor` with a
  timeout, converting a slow, crashing, or raising tool into an error tuple
  instead of letting it take down the caller.
  """

  @spec run((-> term()), timeout()) ::
          {:ok, term()} | {:error, :timeout} | {:error, {:crashed, term()}}
  def run(fun, timeout) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(Illume.ToolSupervisor, fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:error, {:crashed, reason}}

      nil ->
        {:error, :timeout}
    end
  end
end
