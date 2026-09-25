defmodule Hoare.Store.Memory do
  @moduledoc """
  A `Hoare.Store` that keeps records in the calling process, for testing a
  transition without a datastore.

      invoice = Memory.put(%Invoice{id: 1, status: :issued, lines: [line]})
      {:ok, _ctx} = Pay.run(%Pay{record: invoice}, &{:ok, &1}, store: Memory)
      Memory.get(Invoice, 1).status
      #=> :paid

  Records live in the process dictionary, so async tests do not share them.
  The lock is not taken and preloads are ignored: seed a record as loaded as
  the states need it. `read_by/3` scans them, taking the first whose fields
  match, since nothing here enforces that a natural key is unique. `update/1` takes what the schema's `changeset/2`
  returned: anything shaped like an `Ecto.Changeset` (`data`, `changes`,
  `valid?`) or a `{record, attrs}` pair.
  """

  @behaviour Hoare.Store

  alias Hoare.Store

  @spec put(Store.subject()) :: Store.subject()
  def put(%schema{id: id} = record) do
    Process.put({__MODULE__, schema, id}, record)
    record
  end

  @spec get(module(), term()) :: Store.subject() | nil
  def get(schema, id), do: Process.get({__MODULE__, schema, id})

  @spec delete(module(), term()) :: :ok
  def delete(schema, id) do
    Process.delete({__MODULE__, schema, id})
    :ok
  end

  @impl Store
  def transact_with_lock(_lock, fun), do: fun.()

  @impl Store
  def read(schema, id, _preloads) do
    case get(schema, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl Store
  def read_by(schema, key, _preloads) do
    Process.get()
    |> Enum.find_value(fn
      {{__MODULE__, ^schema, _id}, record} -> keyed?(record, key) && record
      _other -> nil
    end)
    |> case do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl Store
  def update(%{valid?: false} = changeset), do: {:error, changeset}
  def update(%{data: record, changes: changes}), do: write(record, changes)
  def update({record, attrs}), do: write(record, attrs)

  # Only the changes are written, as a changeset does: what the body stored stays.
  defp write(%schema{id: id}, changes), do: {:ok, put(struct!(get(schema, id), changes))}

  defp keyed?(record, key),
    do: Enum.all?(key, fn {field, value} -> Map.get(record, field) == value end)
end
