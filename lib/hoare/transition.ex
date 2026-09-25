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
  store's locked transaction, the re-check and the `to` write.

  The commit re-reads the record under the lock and runs `check/2` again on
  it, so a guard runs twice and must be a function of the context alone.
  A guard writes only keys no effect writes, since its second run overwrites
  them.
  Whatever the caller resolved into the context is as stale the second time
  as the first: a condition that has to hold under the lock belongs in a state
  property or a guard that reads the record, with its needs named in
  `preloads`. `preloads/1` is the one list both the caller's fetch and the
  commit's re-read load.

  A transition whose subject is created rather than moved is `Hoare.Intake`,
  which shares all of this but the commit.

  The law: a run ends in `to` or leaves the record in `from`, never between.
  A bare effect must be idempotent, so a commit that fails after it is
  recovered by running again. An effect paired with an undo is reverted,
  newest first, when anything after it fails; an undo that fails raises once
  the older ones have run. A bare effect that ran before a
  failure cannot be reverted: `stranded` is told, with the context and the
  reason, so the domain can alert or queue the retry. A raise is its own report
  and does not reach it.
  """

  import Hoare.Result, only: [kleisli: 1, tap_error: 2]

  alias Hoare.State
  alias Hoare.Store
  alias Hoare.Transition

  defstruct [:from, :to, :stranded, guards: [], effects: [], preloads: []]

  @type ctx :: %{:record => Store.subject(), :state => struct() | nil, optional(atom()) => term()}
  @type arrow :: (ctx() -> {:ok, ctx()} | {:error, term()})
  @type undo :: (ctx() -> :ok)
  @type effect :: arrow() | {arrow(), undo()}
  @type stranded :: (ctx(), reason :: term() -> term())
  @type commit_error :: :not_found | :status_changed
  @type error(reason) :: {:error, reason | commit_error()}
  @type body :: (ctx() -> {:ok, term()} | {:error, term()})
  @type opts :: [store: module(), lock: term()]
  @type t :: %__MODULE__{
          from: [module(), ...],
          to: module(),
          guards: [arrow()],
          effects: [effect()],
          stranded: stranded() | nil,
          preloads: [term()]
        }

  @doc "The guards, in order; none by default."
  @callback guards() :: [arrow()]

  @doc "The effects, in order; none by default."
  @callback effects() :: [effect()]

  @doc "Told when a run fails after a bare effect; wired only when defined."
  @callback stranded(ctx(), reason :: term()) :: term()

  @optional_callbacks stranded: 2

  @doc """
  Declares the transition as the module: the literal parts are options, the
  arrows are callbacks, and the context struct is `record`, `state` and `:ctx`.

      defmodule Pay do
        use Hoare.Transition, from: [Issued], to: Paid, ctx: [:charge]

        import Hoare.Result, only: [ensure: 2]

        @impl Hoare.Transition
        def guards, do: [ensure(&amount_due?/1, :nothing_due)]

        @impl Hoare.Transition
        def effects, do: [&cancel_reminder/1, {&charge/1, &refund/1}]

        @impl Hoare.Transition
        def stranded(ctx, reason), do: Alerts.reminder_cancelled_unpaid(ctx.record, reason)
      end

      Pay.run(%Pay{record: invoice}, &record_payment/1, store: Repo)

  Injects `transition/0`, `check/1`, `run/3`, `preloads/0` and
  `from_statuses/0`. `:preloads` are the transition's own, beyond its states'.
  """
  defmacro __using__(opts) do
    quote do
      @behaviour Hoare.Transition
      @before_compile Hoare.Transition

      @hoare_transition %Hoare.Transition{
        from: unquote(Keyword.fetch!(opts, :from)),
        to: unquote(Keyword.fetch!(opts, :to)),
        preloads: unquote(Keyword.get(opts, :preloads, []))
      }

      defstruct [:record, :state | unquote(Keyword.get(opts, :ctx, []))]

      @impl Hoare.Transition
      def guards, do: []

      @impl Hoare.Transition
      def effects, do: []

      defoverridable guards: 0, effects: 0

      @spec check(Hoare.Transition.ctx()) :: {:ok, Hoare.Transition.ctx()} | {:error, term()}
      def check(ctx), do: Hoare.Transition.check(transition(), ctx)

      @spec run(Hoare.Transition.ctx(), Hoare.Transition.body(), Hoare.Transition.opts()) ::
              {:ok, Hoare.Transition.ctx()} | {:error, term()}
      def run(ctx, body, opts), do: Hoare.Transition.run(transition(), ctx, body, opts)

      @spec preloads() :: [term()]
      def preloads, do: Hoare.Transition.preloads(transition())

      @spec from_statuses() :: [atom()]
      def from_statuses, do: Hoare.Transition.from_statuses(transition())
    end
  end

  defmacro __before_compile__(env) do
    stranded =
      if Module.defines?(env.module, {:stranded, 2}, :def),
        do: quote(do: &__MODULE__.stranded/2)

    quote do
      @spec transition() :: Hoare.Transition.t()
      def transition do
        %{@hoare_transition | guards: guards(), effects: effects(), stranded: unquote(stranded)}
      end
    end
  end

  @doc "The tag values of the states the transition leaves; untagged states contribute none."
  @spec from_statuses(t()) :: [atom()]
  def from_statuses(%Transition{from: from}) do
    Enum.flat_map(from, fn state ->
      case State.tag(state) do
        {_field, value} -> [value]
        nil -> []
      end
    end)
  end

  @doc "Everything the states and guards read: the states' preloads, then the transition's own."
  @spec preloads(t()) :: [term()]
  def preloads(%Transition{from: from, to: to, preloads: own}),
    do: Enum.flat_map(from ++ [to], &State.preloads/1) ++ own

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
  def run(%Transition{} = transition, ctx, body, opts) when is_function(body, 1),
    do: discharge(transition, ctx, &commit(transition, &1, body, &2, opts))

  @doc """
  Discharges the triple with the given commit: the guards, then the effects,
  then `commit`, undoing what ran when it fails.

  `commit` takes the checked context and whether every completed effect was
  bare, and answers with the record the run ends on. `run/4` hands it
  `commit/5`; `Hoare.Intake` hands it one keyed differently.
  """
  @spec discharge(t(), ctx(), (ctx(), boolean() -> {:ok, Store.subject()} | {:error, term()})) ::
          {:ok, ctx()} | {:error, term()}
  def discharge(%Transition{effects: effects} = transition, ctx, commit)
      when is_list(effects) and is_function(commit, 2) do
    with {:ok, ctx} <- check(transition, ctx),
         {:ok, ctx, done} <- perform(transition, ctx),
         {:ok, arrived} <-
           ctx |> commit.(converges?(done)) |> tap_error(&fail(transition, done, ctx, &1)) do
      {:ok, %{ctx | record: arrived}}
    end
  end

  @doc """
  Commits in one locked transaction: re-reads the record with the transition's
  preloads, checks it again, runs `body` on the re-checked context, writes
  `to`'s tag and asserts `to` on a second read.

  A record already in `to` is a concurrent run of the same transition: it
  commits nothing and is `{:ok, record}` when `converges?` (no effect left
  anything behind), `{:error, :status_changed}` otherwise. A record in neither
  is `{:error, :status_changed}`; one still in `from` whose properties or
  guards no longer hold returns their reason. A violated `to` raises, rolling
  the transaction back. The tag is written through the schema's
  `changeset/2`; an untagged `to` has none, so the body's own writes are the
  move and `to` is asserted on the re-read all the same.
  """
  @spec commit(t(), ctx(), body(), boolean(), opts()) ::
          {:ok, Store.subject()} | {:error, :not_found | :status_changed | term()}
  def commit(
        %Transition{to: to} = transition,
        %{record: %schema{id: id}} = ctx,
        body,
        converges?,
        opts
      ) do
    store = Keyword.fetch!(opts, :store)
    lock = Keyword.get(opts, :lock, {schema, id})
    preloads = preloads(transition)

    store.transact_with_lock(lock, fn ->
      with {:ok, current} <- store.read(schema, id, preloads),
           {:from, current} <- position(current, transition),
           {:ok, ctx} <- check(transition, %{ctx | record: current}),
           {:ok, _} <- body.(ctx),
           {:ok, _} <- write_tag(store, schema, current, to),
           {:ok, arrived} <- store.read(schema, id, preloads) do
        arrived!(to, arrived)
      else
        {:to, arrived} when converges? -> {:ok, arrived}
        {:to, _arrived} -> {:error, :status_changed}
        {:error, _} = error -> error
      end
    end)
  end

  defp position(record, %Transition{from: from, to: to}) do
    cond do
      in_state?(to, record) -> {:to, record}
      Enum.any?(from, &in_state?(&1, record)) -> {:from, record}
      true -> {:error, :status_changed}
    end
  end

  # A tagged state is positioned by its tag alone; an untagged one by a full match.
  defp in_state?(state, record) do
    case State.tag(state) do
      {field, value} -> Map.get(record, field) == value
      nil -> match?({:ok, _}, State.match(state, record))
    end
  end

  # An untagged `to` has no tag to write: the body's own writes are the move.
  defp write_tag(store, schema, current, to) do
    case State.tag(to) do
      {field, value} -> store.update(schema.changeset(current, %{field => value}))
      nil -> {:ok, current}
    end
  end

  defp converges?(done), do: Enum.all?(done, &is_function(&1, 1))

  defp perform(%Transition{effects: effects} = transition, ctx) do
    Enum.reduce_while(effects, {:ok, ctx, []}, fn effect, {:ok, ctx, done} ->
      case effect |> arrow() |> apply([ctx]) do
        {:ok, ctx} ->
          {:cont, {:ok, ctx, [effect | done]}}

        {:error, reason} = error ->
          fail(transition, done, ctx, reason)
          {:halt, error}
      end
    end)
  end

  defp arrow({run, _undo}), do: run
  defp arrow(run) when is_function(run, 1), do: run

  # Undoes what can be undone, then reports what cannot: bare effects that ran.
  defp fail(%Transition{stranded: stranded}, done, ctx, reason) do
    undo(done, ctx)
    if stranded && Enum.any?(done, &is_function(&1, 1)), do: stranded.(ctx, reason)
  end

  # Every undo gets its turn; the first that failed is raised once all have run.
  defp undo(done, ctx) do
    done
    |> Enum.flat_map(&revert(&1, ctx))
    |> Enum.take(1)
    |> Enum.each(fn {kind, failure, stacktrace} -> :erlang.raise(kind, failure, stacktrace) end)
  end

  defp revert({_run, undo}, ctx) do
    :ok = undo.(ctx)
    []
  catch
    kind, failure -> [{kind, failure, __STACKTRACE__}]
  end

  defp revert(_idempotent, _ctx), do: []

  defp arrived!(to, record) do
    case State.match(to, record) do
      {:ok, _} -> {:ok, record}
      {:error, reason} -> raise "committed record is not #{inspect(to)}: #{inspect(reason)}"
    end
  end
end
