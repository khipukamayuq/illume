defmodule Illume.MCPServerTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias Illume.MCPServer

  setup do
    target_dir = File.cwd!()
    Application.put_env(:illume, :mcp_server_target_dir, target_dir)
    on_exit(fn -> Application.delete_env(:illume, :mcp_server_target_dir) end)
    {:ok, target_dir: target_dir}
  end

  describe "init/2" do
    test "registers exactly the 5 allowed tools with schemas identical to Tools.specs()" do
      {:ok, frame} = MCPServer.init(%{}, Frame.new())

      assert Map.keys(frame.tools) |> Enum.sort() ==
               Illume.Tools.specs() |> Enum.map(& &1.name) |> Enum.sort()

      for spec <- Illume.Tools.specs() do
        tool = frame.tools[spec.name]
        assert tool.input_schema == spec.input_schema
        assert tool.description == spec.description
        assert tool.handler == nil
        assert is_function(tool.validate_input, 1)
      end
    end
  end

  describe "handle_tool_call/3" do
    setup do
      {:ok, frame} = MCPServer.init(%{}, Frame.new())
      {:ok, frame: frame}
    end

    test "each allowed tool produces the same result Tools.dispatch/4 would", %{
      frame: frame,
      target_dir: target_dir
    } do
      cases = [
        {"read_file", %{"path" => "mix.exs"}},
        {"search_files", %{"pattern" => "*.exs"}},
        {"grep_content", %{"pattern" => "defmodule"}},
        {"git_log", %{}},
        {"git_show", %{"revision" => "HEAD"}}
      ]

      for {name, params} <- cases do
        expected = Illume.Tools.dispatch(name, params, target_dir, :direct)
        {:reply, response, ^frame} = MCPServer.handle_tool_call(name, params, frame)

        case expected do
          {:ok, result} ->
            refute response.isError
            assert response.content == [%{"type" => "text", "text" => to_expected_string(result)}]

          {:error, reason} ->
            assert response.isError
            assert response.content == [%{"type" => "text", "text" => to_expected_string(reason)}]
        end
      end
    end

    test "a disallowed tool name is rejected identically to a direct dispatch/4 call", %{
      frame: frame,
      target_dir: target_dir
    } do
      params = %{"message" => "pwned"}
      expected = Illume.Tools.dispatch("git_commit", params, target_dir, :direct)
      {:reply, response, ^frame} = MCPServer.handle_tool_call("git_commit", params, frame)

      assert expected == {:error, :not_allowed}
      assert response.isError
      assert response.content == [%{"type" => "text", "text" => inspect(:not_allowed)}]
    end

    test "a path-escaping read_file call is rejected the same as a direct dispatch/4 call", %{
      frame: frame,
      target_dir: target_dir
    } do
      params = %{"path" => "../../../etc/passwd"}
      expected = Illume.Tools.dispatch("read_file", params, target_dir, :direct)
      {:reply, response, ^frame} = MCPServer.handle_tool_call("read_file", params, frame)

      assert {:error, _reason} = expected
      assert response.isError
    end

    test "a non-string read_file path is rejected instead of crashing the session", %{
      frame: frame,
      target_dir: target_dir
    } do
      params = %{"path" => 123}
      expected = Illume.Tools.dispatch("read_file", params, target_dir, :direct)
      {:reply, response, ^frame} = MCPServer.handle_tool_call("read_file", params, frame)

      assert {:error, message} = expected
      assert message =~ "invalid path"
      assert response.isError
    end

    test "a non-string search_files pattern is rejected instead of crashing the session", %{
      frame: frame,
      target_dir: target_dir
    } do
      params = %{"pattern" => ["*.ex"]}
      expected = Illume.Tools.dispatch("search_files", params, target_dir, :direct)
      {:reply, response, ^frame} = MCPServer.handle_tool_call("search_files", params, frame)

      assert {:error, message} = expected
      assert message =~ "invalid pattern"
      assert response.isError
    end

    test "a non-string grep_content pattern is rejected instead of crashing the session", %{
      frame: frame,
      target_dir: target_dir
    } do
      params = %{"pattern" => %{"nested" => "map"}}
      expected = Illume.Tools.dispatch("grep_content", params, target_dir, :direct)
      {:reply, response, ^frame} = MCPServer.handle_tool_call("grep_content", params, frame)

      assert {:error, message} = expected
      assert message =~ "invalid pattern"
      assert response.isError
    end

    test "a flag-injecting git_show revision is rejected the same as a direct dispatch/4 call", %{
      frame: frame,
      target_dir: target_dir
    } do
      params = %{"revision" => "--output=/tmp/illume-mcp-server-test"}
      expected = Illume.Tools.dispatch("git_show", params, target_dir, :direct)
      {:reply, response, ^frame} = MCPServer.handle_tool_call("git_show", params, frame)

      assert {:error, message} = expected
      assert message =~ "invalid revision"
      assert response.isError
      refute File.exists?("/tmp/illume-mcp-server-test")
    end
  end

  defp to_expected_string(result) when is_binary(result), do: result
  defp to_expected_string(result) when is_list(result), do: Enum.join(result, "\n")
  defp to_expected_string(result), do: inspect(result)
end
