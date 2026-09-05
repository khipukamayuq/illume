defmodule Illume.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias Illume.Tools.Grep

  @moduletag :tmp_dir

  test "finds a fixed-string match and reports the relative path", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "foo.ex"), "def needle, do: :ok")

    assert {:ok, output} = Grep.grep_content(tmp_dir, %{"pattern" => "needle"})
    assert output =~ "foo.ex"
    assert output =~ "needle"
  end

  test "reports no matches without treating it as an error", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "foo.ex"), "nothing interesting here")
    assert Grep.grep_content(tmp_dir, %{"pattern" => "needle"}) == {:ok, "no matches"}
  end

  test "treats the pattern as a fixed string, not a regex", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "foo.ex"), "a.b")
    assert {:ok, output} = Grep.grep_content(tmp_dir, %{"pattern" => "a.b"})
    assert output =~ "foo.ex"
    assert Grep.grep_content(tmp_dir, %{"pattern" => "axb"}) == {:ok, "no matches"}
  end

  test "caps matches per file so one huge file can't blow up the result", %{tmp_dir: tmp_dir} do
    content = Enum.map_join(1..1000, "\n", &"needle line #{&1}")
    File.write!(Path.join(tmp_dir, "big.txt"), content)

    assert {:ok, output} = Grep.grep_content(tmp_dir, %{"pattern" => "needle"})
    assert length(String.split(output, "\n")) == 200
  end

  test "rejects a subdirectory path that escapes the target dir", %{tmp_dir: tmp_dir} do
    assert {:error, message} =
             Grep.grep_content(tmp_dir, %{"pattern" => "needle", "path" => "../../../../etc"})

    assert message =~ "escapes target directory"
  end
end
