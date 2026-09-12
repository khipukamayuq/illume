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
      text_result("/target/lib/foo.ex")
    end)

    assert MCP.search_files("/target", %{"pattern" => "*.ex"}) == {:ok, "/target/lib/foo.ex"}
  end

  test "search_files passes through the server's own no-matches sentinel unchanged" do
    expect(ClientMock, :call_tool, fn Illume.MCP.FilesystemClient, "search_files", _args ->
      text_result("No matches found")
    end)

    assert MCP.search_files("/target", %{"pattern" => "nope"}) == {:ok, "No matches found"}
  end

  test "search_files filters out a match that resolves outside target_dir" do
    expect(ClientMock, :call_tool, fn Illume.MCP.FilesystemClient, "search_files", _args ->
      text_result("/target/lib/foo.ex\n/etc/passwd")
    end)

    assert MCP.search_files("/target", %{"pattern" => "*"}) == {:ok, "/target/lib/foo.ex"}
  end

  test "search_files rejects a relative match instead of resolving it against this VM's cwd" do
    # Deliberately use this VM's own cwd as target_dir: if confinement ever
    # resolved a relative match via Path.expand/1's cwd-relative default
    # (instead of requiring the server's own matches to already be
    # absolute), a relative match would incorrectly resolve to somewhere
    # under this same root and pass — even though the server never claimed
    # that path at all.
    root = File.cwd!()

    expect(ClientMock, :call_tool, fn Illume.MCP.FilesystemClient, "search_files", _args ->
      text_result("#{root}/lib/foo.ex\nrelative/sneaky.ex")
    end)

    assert MCP.search_files(root, %{"pattern" => "*"}) == {:ok, "#{root}/lib/foo.ex"}
  end

  test "search_files emits a confinement_violation telemetry event when a match escapes target_dir" do
    expect(ClientMock, :call_tool, fn Illume.MCP.FilesystemClient, "search_files", _args ->
      text_result("/etc/passwd")
    end)

    test_pid = self()
    handler_id = "mcp-confinement-violation-test"

    :telemetry.attach(
      handler_id,
      [:illume, :mcp, :confinement_violation],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert MCP.search_files("/target", %{"pattern" => "*"}) == {:ok, "No matches found"}
    assert_receive {:telemetry_event, metadata}
    assert metadata.tool == "search_files"
    assert metadata.path == "/etc/passwd"
    assert metadata.root == "/target"
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
