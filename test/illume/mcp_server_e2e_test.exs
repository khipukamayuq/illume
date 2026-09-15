defmodule Illume.MCPServerE2ETest do
  @moduledoc """
  One real end-to-end round-trip proving the whole `--serve` stack works —
  not just the function-level coverage in `mcp_server_test.exs`. Spawns our
  own compiled escript as a real OS subprocess over real stdio (see
  DECISIONS.md entry 51 for why this is acceptable against the spec's
  "no subprocess" guidance and entry 52 for why it's excluded from the
  default `mix test` run). Run explicitly with `mix test --only e2e`.
  """

  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 30_000

  @escript_path Path.expand("../../illume", __DIR__)

  setup_all do
    {output, 0} = System.cmd("mix", ["escript.build"], cd: File.cwd!(), stderr_to_stdout: true)
    IO.puts(output)
    :ok
  end

  test "protocol handshake, tool listing, and a real tool call round-trip over stdio" do
    target_dir = File.cwd!()
    client_name = :"illume_e2e_client_#{System.unique_integer([:positive])}"

    {:ok, _client_sup} =
      Anubis.Client.start_link(
        name: client_name,
        transport: {:stdio, command: @escript_path, args: ["--serve", target_dir]},
        client_info: %{"name" => "illume-e2e-test", "version" => "0.1.0"},
        capabilities: %{}
      )

    # No explicit teardown call: `Anubis.Client.start_link/1`'s supervisor
    # is linked to this test process, so it (and the escript subprocess
    # under it) is torn down automatically via that link's EXIT signal once
    # the test ends. A manual `Supervisor.stop/1` here was observed to crash
    # this test's own BEAM with a `badarg` from inside its own EXIT report,
    # racing against the *server*'s restart-storm crash on EOF (see
    # DECISIONS.md entry 53) — avoided rather than chased further, since the
    # goal here is one clean round-trip proof, not surviving disconnect
    # races on both sides at once.
    assert :ok = Anubis.Client.await_ready(client_name, timeout: 15_000)

    assert {:ok, tools_response} = Anubis.Client.list_tools(client_name)

    names =
      tools_response.result["tools"]
      |> Enum.map(& &1["name"])
      |> Enum.sort()

    assert names == Enum.sort(~w(read_file search_files grep_content git_log git_show))

    assert {:ok, call_response} =
             Anubis.Client.call_tool(client_name, "read_file", %{"path" => "mix.exs"})

    refute call_response.is_error

    text = Enum.map_join(call_response.result["content"], & &1["text"])

    assert text =~ "defmodule Illume.MixProject"
  end
end
