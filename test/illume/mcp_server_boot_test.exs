defmodule Illume.MCPServerBootTest do
  @moduledoc """
  In-process coverage that `--serve` actually boots something under
  `Illume.MCPServerSupervisor` — closing the gap where the default
  `mix test` run had zero proof of that (only the `:e2e`-tagged,
  excluded-by-default `mcp_server_e2e_test.exs` covers it, via a real
  OS subprocess).

  Deliberately does **not** start the real `{Illume.MCPServer, transport:
  :stdio}` child `--serve` actually uses — confirmed empirically (see
  DECISIONS.md entry 70) that doing so inside the shared `mix test` BEAM
  is unsafe: `mix test`'s own stdin is already at EOF, which triggers
  `anubis_mcp`'s documented stdin-EOF restart storm (DECISIONS.md entry
  53) *synchronously, within the `DynamicSupervisor.start_child/2` call
  itself* — a real risk of exhausting the supervisor's restart budget
  and crashing the whole test run, not just one test. Starts the same
  child spec with `{:streamable_http, start: true}` instead, which
  touches no real stdio and doesn't bind a network port itself (it's a
  mountable Plug transport, not a standalone HTTP server) — enough to
  prove the supervisor accepts `Illume.MCPServer`'s child spec and it
  initializes without crashing. Tool-registration correctness itself is
  already covered directly in `mcp_server_test.exs`'s `init/2` test;
  this file only closes the "does starting it under the real supervisor
  work at all" gap.
  """

  use ExUnit.Case, async: false

  setup do
    Application.put_env(:illume, :mcp_server_target_dir, File.cwd!())
    on_exit(fn -> Application.delete_env(:illume, :mcp_server_target_dir) end)
    :ok
  end

  test "Illume.MCPServerSupervisor starts Illume.MCPServer and can clean it up" do
    assert {:ok, pid} =
             DynamicSupervisor.start_child(
               Illume.MCPServerSupervisor,
               {Illume.MCPServer, transport: {:streamable_http, start: true}}
             )

    assert Process.alive?(pid)
    assert :ok = DynamicSupervisor.terminate_child(Illume.MCPServerSupervisor, pid)
    refute Process.alive?(pid)
  end
end
