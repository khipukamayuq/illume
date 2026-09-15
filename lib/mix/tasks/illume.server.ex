defmodule Mix.Tasks.Illume.Server do
  @moduledoc """
  Starts the Illume LiveView web front end for local browsing.

      mix illume.server

  Starts `Illume.Application`'s normal children via
  `Application.ensure_all_started/1` (never `Application.start/2` — this
  must go through the same boot path as any other invocation, escript
  included), then `Illume.Endpoint` and its `Phoenix.PubSub` under a
  separate, on-demand `Supervisor` started directly by this task —
  `Illume.Application`'s own children list is unchanged (see DECISIONS.md
  entry 57). The plain CLI/escript path never touches this task or
  `Illume.Endpoint` at all.

  `target_dir` for the web form is illume's own checkout, hardcoded in
  `Illume.QuestionLive` — never free text from an HTTP request.

  Ctrl-C during `mix illume.server` just kills the BEAM without running
  any `terminate/2` cleanup: Elixir cannot trap `:sigint` (see
  DECISIONS.md entry 41), the same limitation `Illume.CLI`'s moduledoc
  already documents for `--mcp`/`--serve`.
  """

  @shortdoc "Starts the Illume LiveView web server"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    if Mix.env() == :prod do
      Mix.raise("illume.server is a local dev tool; MIX_ENV=prod is unsupported")
    end

    Mix.Task.run("app.config")

    endpoint_config = Application.get_env(:illume, Illume.Endpoint, [])
    Application.put_env(:illume, Illume.Endpoint, Keyword.put(endpoint_config, :server, true))

    # Generated once per `mix illume.server` run and checked by
    # `QuestionLive.mount/3` — the only realistic delivery path for M2
    # (an unauthenticated local endpoint driving billed Anthropic calls)
    # is a non-browser local client with no `Origin` header, which
    # `check_origin` can't stop; a shared token is the security review's
    # own proportionate fix for a single-user dev tool (see DECISIONS.md
    # entry 64). Same one-shot `Application.put_env/3` pattern as
    # `mcp_server_target_dir` (DECISIONS.md #50).
    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Application.put_env(:illume, :web_token, token)

    {:ok, _apps} = Application.ensure_all_started(:illume)

    {:ok, _pid} =
      Supervisor.start_link(
        [{Phoenix.PubSub, name: Illume.PubSub}, Illume.Endpoint],
        strategy: :one_for_one,
        name: Illume.ServerSupervisor
      )

    port = Keyword.fetch!(Illume.Endpoint.config(:http), :port)
    Mix.shell().info("Illume running at http://localhost:#{port}?token=#{token}")

    Process.sleep(:infinity)
  end
end
