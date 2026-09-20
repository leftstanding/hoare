defmodule Hoare.Transition do
  @moduledoc """
  A declared transition: the states it leaves, the state it reaches, the
  guards that must hold and the effects it performs, each list composed as one
  Kleisli arrow. `{from, guards} body {to}` is the Hoare triple; `run/4`
  discharges it.

  `from` and `to` are `Hoare.State` modules. The context is any map or struct
  with a `record` key, the record whose status moves, and a `state` key, which
  `check/2` fills by matching `from`. Each arrow is
  `ctx -> {:ok, ctx} | {:error, reason}` and may refine the context it returns.
  The domain declares the transition; the module owning the records supplies
  the body of the commit when it runs it, and `commit/5` wraps that body in the
  store's locked transaction, the `from` re-check and the `to` write.

  The law: a run ends in `to` or leaves the record in `from`, never between.
  A bare effect must be idempotent, so a commit that fails after it is
  recovered by running again. An effect paired with an undo is reverted,
  newest first, when anything after it fails.
  """

  import Hoare.Result, only: [kleisli: 1, tap_error: 2]

  alias Hoare.State
  alias Hoare.Store
  alias Hoare.Transition

  defstruct [:from, :to, guards: [], effects: []]

  @type ctx :: %{:record => Store.subject(), :state => struct() | nil, optional(atom()) => term()}
  @type arrow :: (ctx() -> {:ok, ctx()} | {:error, term()})
  @type undo :: (ctx() -> :ok)
  @type effect :: arrow() | {arrow(), undo()}
  @type body :: (ctx() -> {:ok, term()} | {:error, term()})
  @type opts :: [store: module(), lock: term()]
  @type t :: %__MODULE__{
          from: [module(), ...],
          to: module(),
          guards: [arrow()],
          effects: [effect()]
        }

  @doc "Matches `from` into the context's `state`, then runs the guards."
  @spec check(t(), ctx()) :: {:ok, ctx()} | {:error, term()}
  def check(%Transition{from: from, guards: guards}, %{record: record} = ctx) do
    with {:ok, state} <- State.match_any(from, record),
         do: kleisli(guards).(%{ctx | state: state})
  end

  @doc """
  Runs the transition end to end: guards, then effects, then the commit.

  `body` is the domain's own writes; `commit/5` wraps them. On success the
  context comes back with `record` replaced by the committed record. `opts`
  needs `:store`, a `Hoare.Store`; `:lock` defaults to `{schema, id}`.
  """
  @spec run(t(), ctx(), body(), opts()) :: {:ok, ctx()} | {:error, term()}
  def run(%Transition{effects: effects} = transition, ctx, body, opts)
      when is_list(effects) and is_function(body, 1) do
    with {:ok, ctx} <- check(transition, ctx),
         {:ok, ctx, done} <- perform(effects, ctx),
         {:ok, arrived} <-
           transition
           |> commit(ctx, body, converges?(done), opts)
           |> tap_error(fn _ -> undo(done, ctx) end) do
      {:ok, %{ctx | record: arrived}}
    end
  end

  @doc """
  Commits in one locked transaction: re-reads the record, confirms it is still
  tagged by a `from` state, runs `body`, writes `to`'s status and asserts `to`.

  A record already tagged by `to` is a concurrent run of the same transition:
  it commits nothing and is `{:ok, record}` when `converges?` (no effect left
  anything behind), `{:error, :status_changed}` otherwise. A violated `to`
  raises, rolling the transaction back. The re-read carries no preloads, so
  only the tag is re-checked; the properties held on the context under the
  guards. The status is written through the schema's `changeset/2`.
  """
  @spec commit(t(), ctx(), body(), boolean(), opts()) ::
          {:ok, Store.subject()} | {:error, :not_found | :status_changed | term()}
  def commit(
        %Transition{from: from, to: to},
        %{record: %schema{id: id} = record} = ctx,
        body,
        converges?,
        opts
      ) do
    store = Keyword.fetch!(opts, :store)
    lock = Keyword.get(opts, :lock, {schema, id})

    store.transact_with_lock(lock, fn ->
      with {:ok, current} <- store.fetch(schema, id),
           :from <- position(current, from, to),
           {:ok, _} <- body.(ctx),
           {:ok, arrived} <- store.update(schema.changeset(record, %{status: to.status()})) do
        arrived!(to, arrived)
      else
        :to when converges? -> {:ok, %{record | status: to.status()}}
        :to -> {:error, :status_changed}
        {:error, _} = error -> error
      end
    end)
  end

  defp position(%{status: status}, from, to) do
    cond do
      status == to.status() -> :to
      status in Enum.map(from, & &1.status()) -> :from
      true -> {:error, :status_changed}
    end
  end

  defp converges?(done), do: Enum.all?(done, &is_function(&1, 1))

  defp perform(effects, ctx) do
    Enum.reduce_while(effects, {:ok, ctx, []}, fn effect, {:ok, ctx, done} ->
      case effect |> arrow() |> apply([ctx]) do
        {:ok, ctx} ->
          {:cont, {:ok, ctx, [effect | done]}}

        {:error, _} = error ->
          undo(done, ctx)
          {:halt, error}
      end
    end)
  end

  defp arrow({run, _undo}), do: run
  defp arrow(run) when is_function(run, 1), do: run

  defp undo(done, ctx), do: Enum.each(done, &revert(&1, ctx))

  defp revert({_run, undo}, ctx), do: :ok = undo.(ctx)
  defp revert(_idempotent, _ctx), do: :ok

  defp arrived!(to, record) do
    case State.match(to, record) do
      {:ok, _} -> {:ok, record}
      {:error, reason} -> raise "committed record is not #{inspect(to)}: #{inspect(reason)}"
    end
  end
end
