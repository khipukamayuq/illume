defmodule Illume.QA do
  @moduledoc """
  Runs a single question against a single target directory: starts an
  `Illume.Agent` under `Illume.AgentSupervisor` and blocks on `ask/2`.
  Extracted from `Illume.CLI` so Component 3's LiveView can call the same
  question-runner the CLI does, rather than duplicating the
  supervisor/agent dance (see DECISIONS.md entry 54).

  `opts` is passed straight through to `Illume.Agent`'s `init/1` (e.g.
  `model_timeout`, `tool_timeout`) — not new surface, just not hardcoded
  away by the extraction.
  """

  @spec ask(Path.t(), String.t(), Illume.Tools.backend(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def ask(target_dir, question, backend, opts \\ []) do
    child_spec =
      Supervisor.child_spec(
        {Illume.Agent, [target_dir: target_dir, tool_backend: backend] ++ opts},
        restart: :temporary
      )

    {:ok, pid} = DynamicSupervisor.start_child(Illume.AgentSupervisor, child_spec)
    Illume.Agent.ask(pid, question)
  end
end
