defmodule Illume.QA do
  @moduledoc """
  Runs a single question against a single target directory: starts an
  `Illume.Agent` under `Illume.AgentSupervisor` and blocks on `ask/2`.
  Extracted from `Illume.CLI` so Component 3's LiveView can call the same
  question-runner the CLI does, rather than duplicating the
  supervisor/agent dance (see DECISIONS.md's "Shared question-runner
  (Component 2)" section).

  `opts` is passed straight through to `Illume.Agent`'s `init/1` (e.g.
  `model_timeout`, `tool_timeout`) — not new surface, just not hardcoded
  away by the extraction.
  """

  @spec ask(Path.t(), String.t(), Illume.Tools.backend(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def ask(target_dir, question, backend, opts \\ []) do
    child_spec =
      Supervisor.child_spec(
        {Illume.Agent, [target_dir: target_dir, tool_backend: backend] ++ opts},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(Illume.AgentSupervisor, child_spec) do
      {:ok, pid} -> Illume.Agent.ask(pid, question)
      {:error, reason} -> {:error, "could not start agent: #{inspect(reason)}"}
    end
  end
end
