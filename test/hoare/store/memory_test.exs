defmodule Hoare.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias Hoare.Store.Memory

  defmodule Record do
    defstruct [:id, :status, :note]
  end

  describe "read/3" do
    test "returns what was put, whatever the preloads" do
      record = Memory.put(%Record{id: 1, status: :A})

      assert Memory.read(Record, 1, [:anything]) == {:ok, record}
    end

    test "is :not_found for a record never put or deleted" do
      assert Memory.read(Record, 1, []) == {:error, :not_found}

      Memory.put(%Record{id: 1, status: :A})
      :ok = Memory.delete(Record, 1)

      assert Memory.read(Record, 1, []) == {:error, :not_found}
    end

    test "does not see another process's records" do
      Task.await(Task.async(fn -> Memory.put(%Record{id: 1, status: :A}) end))

      assert Memory.get(Record, 1) == nil
    end
  end

  describe "read_by/3" do
    test "returns the record whose fields match every one of the key's" do
      Memory.put(%Record{id: 1, status: :A, note: "other"})
      record = Memory.put(%Record{id: 2, status: :B, note: "wanted"})

      assert Memory.read_by(Record, [status: :B, note: "wanted"], [:anything]) == {:ok, record}
    end

    test "is :not_found when no record matches the whole key" do
      Memory.put(%Record{id: 1, status: :A, note: "wanted"})

      assert Memory.read_by(Record, [status: :B, note: "wanted"], []) == {:error, :not_found}
    end

    test "does not answer with another schema's record" do
      Memory.put(%Record{id: 1, status: :A})

      assert Memory.read_by(Hoare.Store.MemoryTest, [status: :A], []) == {:error, :not_found}
    end
  end

  describe "update/1" do
    setup do
      %{record: Memory.put(%Record{id: 1, status: :A, note: "kept"})}
    end

    test "writes a changeset-shaped map's changes onto the stored record", %{record: record} do
      Memory.put(%{record | note: "written by the body"})

      assert Memory.update(%{data: record, changes: %{status: :B}, valid?: true}) ==
               {:ok, %Record{id: 1, status: :B, note: "written by the body"}}

      assert Memory.get(Record, 1).status == :B
    end

    test "writes a {record, attrs} pair", %{record: record} do
      assert Memory.update({record, %{status: :B}}) ==
               {:ok, %Record{id: 1, status: :B, note: "kept"}}
    end

    test "returns an invalid changeset and writes nothing", %{record: record} do
      changeset = %{data: record, changes: %{status: :B}, valid?: false}

      assert Memory.update(changeset) == {:error, changeset}
      assert Memory.get(Record, 1) == record
    end
  end

  describe "transact_with_lock/2" do
    test "returns the function's result" do
      assert Memory.transact_with_lock(:any, fn -> {:ok, :done} end) == {:ok, :done}
    end
  end
end
