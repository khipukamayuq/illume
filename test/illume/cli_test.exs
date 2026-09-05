defmodule Illume.CLITest do
  use ExUnit.Case, async: true

  alias Illume.CLI

  @moduletag :tmp_dir

  describe "parse_args/1" do
    test "parses <target_dir> <question> as the :direct backend" do
      assert CLI.parse_args(["/some/dir", "a question"]) ==
               {:ok, "/some/dir", "a question", :direct}
    end

    test "parses --mcp <target_dir> <question> as the :mcp backend" do
      assert CLI.parse_args(["--mcp", "/some/dir", "a question"]) ==
               {:ok, "/some/dir", "a question", :mcp}
    end

    test "returns :error for wrong arity or unrecognized flags" do
      assert CLI.parse_args([]) == :error
      assert CLI.parse_args(["only_one_arg"]) == :error
      assert CLI.parse_args(["--unknown", "dir", "question"]) == :error
      assert CLI.parse_args(["dir", "question", "extra"]) == :error
    end
  end

  describe "validate/1" do
    setup do
      original = System.get_env("ANTHROPIC_API_KEY")
      on_exit(fn -> restore_env(original) end)
      :ok
    end

    defp restore_env(nil), do: System.delete_env("ANTHROPIC_API_KEY")
    defp restore_env(value), do: System.put_env("ANTHROPIC_API_KEY", value)

    test "ok when the directory exists and an API key is set", %{tmp_dir: tmp_dir} do
      System.put_env("ANTHROPIC_API_KEY", "sk-test")
      assert CLI.validate(tmp_dir) == :ok
    end

    test "errors when the directory does not exist" do
      System.put_env("ANTHROPIC_API_KEY", "sk-test")
      assert {:error, message} = CLI.validate("/no/such/directory")
      assert message =~ "is not a directory"
    end

    test "errors when the API key is not set", %{tmp_dir: tmp_dir} do
      System.delete_env("ANTHROPIC_API_KEY")
      assert {:error, message} = CLI.validate(tmp_dir)
      assert message =~ "ANTHROPIC_API_KEY"
    end
  end
end
