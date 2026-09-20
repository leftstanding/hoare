defmodule Hoare.ResultTest do
  use ExUnit.Case, async: true

  import Hoare.Result

  describe "bind/2" do
    test "applies the arrow to an ok value" do
      assert bind({:ok, 1}, &{:ok, &1 + 1}) == {:ok, 2}
      assert bind({:ok, 1}, fn _ -> {:error, :nope} end) == {:error, :nope}
    end

    test "passes an error through untouched" do
      assert bind({:error, :nope}, fn _ -> flunk("arrow ran") end) == {:error, :nope}
    end
  end

  describe "kleisli/1" do
    test "composes arrows left to right" do
      arrow = kleisli([&{:ok, &1 + 1}, &{:ok, &1 * 10}])

      assert arrow.(1) == {:ok, 20}
    end

    test "stops at the first error" do
      arrow = kleisli([&{:ok, &1}, fn _ -> {:error, :blocked} end, fn _ -> flunk("ran") end])

      assert arrow.(1) == {:error, :blocked}
    end

    test "the empty list is the identity" do
      assert kleisli([]).(:x) == {:ok, :x}
    end
  end

  describe "tap_ok/2 and tap_error/2" do
    test "run the function on their side only and return the input" do
      assert tap_ok({:ok, 1}, &send(self(), {:ok_seen, &1})) == {:ok, 1}
      assert_received {:ok_seen, 1}

      assert tap_ok({:error, :e}, fn _ -> flunk("ran") end) == {:error, :e}

      assert tap_error({:error, :e}, &send(self(), {:error_seen, &1})) == {:error, :e}
      assert_received {:error_seen, :e}

      assert tap_error({:ok, 1}, fn _ -> flunk("ran") end) == {:ok, 1}
    end
  end

  describe "map_error/2" do
    test "maps the reason and leaves ok alone" do
      assert map_error({:error, {:status_changed, :X}}, &elem(&1, 0)) == {:error, :status_changed}
      assert map_error({:ok, 1}, fn _ -> flunk("ran") end) == {:ok, 1}
    end
  end
end
