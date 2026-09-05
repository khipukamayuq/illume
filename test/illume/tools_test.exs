defmodule Illume.ToolsTest do
  use ExUnit.Case, async: true

  alias Illume.Tools

  describe "allowed?/1" do
    test "allows exactly the five read-only tools" do
      assert Tools.allowed?("read_file")
      assert Tools.allowed?("search_files")
      assert Tools.allowed?("grep_content")
      assert Tools.allowed?("git_log")
      assert Tools.allowed?("git_show")
    end

    test "rejects write/destructive tool names even though the underlying git/filesystem servers offer them" do
      refute Tools.allowed?("write_file")
      refute Tools.allowed?("edit_file")
      refute Tools.allowed?("move_file")
      refute Tools.allowed?("create_directory")
      refute Tools.allowed?("git_commit")
      refute Tools.allowed?("git_add")
      refute Tools.allowed?("git_reset")
      refute Tools.allowed?("git_checkout")
      refute Tools.allowed?("git_create_branch")
    end
  end

  describe "dispatch/3" do
    test "a disallowed name is rejected without ever reaching a tool implementation" do
      assert Tools.dispatch("git_commit", %{"message" => "pwned"}, "/tmp") ==
               {:error, :not_allowed}

      assert Tools.dispatch("write_file", %{"path" => "x", "content" => "y"}, "/tmp") ==
               {:error, :not_allowed}
    end

    test "an allowed name reaches the real implementation" do
      assert {:ok, _files} = Tools.dispatch("search_files", %{"pattern" => "*.exs"}, File.cwd!())
    end
  end

  describe "specs/0" do
    test "returns a schema for exactly the allowed tools, with no leaked internal markers" do
      names = Tools.specs() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == Enum.sort(~w(read_file search_files grep_content git_log git_show))

      for spec <- Tools.specs() do
        refute Map.has_key?(spec, :__function__)
        refute Map.has_key?(spec, :__beta__)
      end
    end
  end
end
