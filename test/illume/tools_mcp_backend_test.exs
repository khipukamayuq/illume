defmodule Illume.ToolsMCPBackendTest do
  @moduledoc "Exercises `Illume.Tools.dispatch/4`'s `:mcp` routing branch."

  use ExUnit.Case, async: true

  import Mox

  alias Illume.Tools
  alias Illume.Tools.MCP.ClientMock

  setup :verify_on_exit!

  test "dispatch/4 routes read_file through Illume.Tools.MCP under the :mcp backend" do
    expect(ClientMock, :call_tool, fn Illume.MCP.FilesystemClient,
                                      "read_text_file",
                                      %{"path" => "mix.exs"} ->
      {:ok, %{result: %{"content" => [%{"type" => "text", "text" => "hi"}]}, is_error: false}}
    end)

    assert Tools.dispatch("read_file", %{"path" => "mix.exs"}, "/target", :mcp) == {:ok, "hi"}
  end

  @tag :tmp_dir
  test "grep_content stays local even when the :mcp backend is requested", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "needle.txt"), "the needle is here")

    assert {:ok, output} = Tools.dispatch("grep_content", %{"pattern" => "needle"}, tmp_dir, :mcp)
    assert output =~ "needle.txt"
  end

  test "dispatch/3 (no explicit backend) defaults to :direct" do
    assert {:ok, _matches} = Tools.dispatch("search_files", %{"pattern" => "*.exs"}, File.cwd!())
  end
end
