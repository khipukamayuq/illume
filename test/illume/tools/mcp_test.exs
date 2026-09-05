defmodule Illume.Tools.MCPTest do
  use ExUnit.Case, async: true

  import Mox

  alias Illume.Tools.MCP
  alias Illume.Tools.MCP.ClientMock

  setup :verify_on_exit!

  defp text_result(text, is_error? \\ false) do
    result = %{"content" => [%{"type" => "text", "text" => text}]}
    result = if is_error?, do: Map.put(result, "isError", true), else: result
    {:ok, %{result: result, is_error: is_error?}}
  end

  test "read_file returns the text content of a successful tool result" do
    expect(ClientMock, :call_tool, fn Illume.MCP.FilesystemClient,
                                      "read_text_file",
                                      %{"path" => "mix.exs"} ->
      text_result("file contents")
    end)

    assert MCP.read_file("/target", %{"path" => "mix.exs"}) == {:ok, "file contents"}
  end

  test "read_file returns an error for a domain-level (isError) tool result" do
    expect(ClientMock, :call_tool, fn _client, "read_text_file", _args ->
      text_result("no such file", true)
    end)

    assert MCP.read_file("/target", %{"path" => "missing.txt"}) == {:error, "no such file"}
  end

  test "search_files scopes the search to the target dir and forwards the pattern" do
    expect(ClientMock, :call_tool, fn Illume.MCP.FilesystemClient,
                                      "search_files",
                                      %{"path" => "/target", "pattern" => "*.ex"} ->
      text_result("lib/foo.ex")
    end)

    assert MCP.search_files("/target", %{"pattern" => "*.ex"}) == {:ok, "lib/foo.ex"}
  end

  test "git_log forwards max_count when present, omits it otherwise" do
    expect(ClientMock, :call_tool, fn Illume.MCP.GitClient,
                                      "git_log",
                                      %{"repo_path" => "/target", "max_count" => 5} ->
      text_result("abc123 first commit")
    end)

    assert {:ok, _} = MCP.git_log("/target", %{"max_count" => 5})

    expect(ClientMock, :call_tool, fn Illume.MCP.GitClient,
                                      "git_log",
                                      %{"repo_path" => "/target"} = args ->
      refute Map.has_key?(args, "max_count")
      text_result("abc123 first commit")
    end)

    assert {:ok, _} = MCP.git_log("/target", %{})
  end

  test "git_show forwards the revision" do
    expect(ClientMock, :call_tool, fn Illume.MCP.GitClient,
                                      "git_show",
                                      %{"repo_path" => "/target", "revision" => "abc123"} ->
      text_result("commit abc123\n\ndiff")
    end)

    assert MCP.git_show("/target", %{"revision" => "abc123"}) == {:ok, "commit abc123\n\ndiff"}
  end

  test "a transport/protocol error is formatted from the reason and message" do
    expect(ClientMock, :call_tool, fn _client, "git_log", _args ->
      {:error, %Anubis.MCP.Error{reason: :timeout, message: "Timeout"}}
    end)

    assert MCP.git_log("/target", %{}) == {:error, "timeout: Timeout"}
  end
end
