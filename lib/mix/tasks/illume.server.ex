defmodule Mix.Tasks.Illume.Server do
  @moduledoc """
  Starts the Illume LiveView web front end for local browsing.

      mix illume.server

  Starts `Illume.Application`'s normal children via
  `Application.ensure_all_started/1` (never `Application.start/2` — this
  must go through the same boot path as any other invocation, escript
  included), then `Illume.Endpoint` and its `Phoenix.PubSub` under a
  separate, on-demand `Supervisor` started directly by this task —
  `Illume.Application`'s own children list is unchanged (see DECISIONS.md's
  "`mix illume.server` starts `Illume.Endpoint` under its own supervisor"
  note under "Web front end (Component 3)"). The plain CLI/escript path
  never touches this task or `Illume.Endpoint` at all.

  `target_dir` for the web form is illume's own checkout, hardcoded in
  `Illume.QuestionLive` — never free text from an HTTP request.

  Ctrl-C during `mix illume.server` just kills the BEAM without running
  any `terminate/2` cleanup: Elixir cannot trap `:sigint` (see
  DECISIONS.md's "MCP subprocess cleanup" note under "Hardening pass 1"),
  the same limitation `Illume.CLI`'s moduledoc already documents for
  `--mcp`/`--serve`.

  Generates a random bearer token once per run and prints it as part of
  the startup URL, checked by `QuestionLive.mount/3`/`handle_event/3` —
  the security review's own proportionate fix for a single-user dev tool
  against a non-browser local client, which `check_origin` can't stop
  (see DECISIONS.md's "Bearer-token auth on the web endpoint" note under
  "Hardening pass 2").
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
