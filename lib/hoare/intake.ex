defmodule Hoare.Intake do
  @moduledoc """
  A transition whose subject changes: `from` is a state of the payload and
  `to` the state of a record that does not exist yet.

  Everything a payload has to be before it may enter is an ordinary untagged
  state over the incoming map, so validation stops being a step before the
  transition and becomes its precondition, in the same vocabulary as every
  other state. The payload states are vertices like any other, so
  `Hoare.Graph` draws the way in rather than an arrow from nowhere.

      defmodule ValidInvoice do
        use Hoare.State, witnesses: [:number, :account_id, :external_id]

        @impl Hoare.State
        def properties, do: [&numbered/1, &account/1]
        ...
      end

      defmodule Receive do
        use Hoare.Intake,
          from: [ValidInvoice],
          to: Issued,
          schema: MyApp.Invoice,
          key: [:number, :account_id],
          identity: [:external_id]

        @impl Hoare.Transition
        def effects, do: [&archive_payload/1]
      end

      Receive.run(%Receive{record: params}, &insert_invoice/1, store: Repo)

  `key` and `identity` name **witnesses of the matched `from` state**, which
  are read as fields of the record too. The key selects the row, so it is the
  natural key the datastore itself enforces; identity confirms the row found
  is the same thing arriving again. Naming a witness the payload does not
  resolve raises, which is the point: nothing may be keyed on what was never
  established.

  ## The commit

  The same skeleton as `Hoare.Transition`, reading by key rather than by id:
  the lock is `{schema, key}`, the read is `read_by/3`, and where a record is
  positioned against `from` and `to` a row either exists or does not.

  - No row: the body creates it, and `to` is asserted on the row read back
    under the key. A body that creates nothing under the key raises, as does
    one whose row is not in `to`.
  - A row matching `identity`: the same payload arriving again. It converges
    as `{:ok, record}` when every completed effect was bare, and is
    `{:error, :already_exists}`, with the undos run, otherwise.
  - A row that does not match: `{:error, :conflict}`. One key, two things.

  The found row is returned as it stands, and `to` is asserted only on the
  row the body creates. A record has a life after it arrives, and the
  transitions that moved it are what answer for where it is now; re-asserting
  `to` here would refuse a replay for having been fulfilled. What intake
  promises is narrower and exact: a record exists under this key, it is this
  same thing, and it was in `to` when it was created.

  That last clause rests on every writer of the record being declared. A row
  some undeclared write put there is indistinguishable from a replay, so an
  intake is only as good as the coverage around it.
  """

  alias Hoare.Intake
  alias Hoare.State
  alias Hoare.Store
  alias Hoare.Transition

  defstruct [:transition, :schema, :key, identity: []]

  @type commit_error :: :conflict | :already_exists
  @type error(reason) :: {:error, reason | commit_error()}
  @type opts :: [store: module(), lock: term()]
  @type t :: %__MODULE__{
          transition: Transition.t(),
          schema: module(),
          key: [atom(), ...],
          identity: [atom()]
        }

  @doc """
  Declares the intake as the module, as `Hoare.Transition` does, over the
  record `schema` it creates and the `key` and `identity` that find it.

  `:key` and `:identity` are witnesses of the `from` states; `:identity`
  defaults to none, which makes the key alone the identity. Injects
  `intake/0`, `check/1`, `run/3` and `preloads/0`; `guards/0`, `effects/0`
  and `stranded/2` are the `Hoare.Transition` callbacks, unchanged.
  """
  defmacro __using__(opts) do
    quote do
      @behaviour Hoare.Transition
      @before_compile Hoare.Intake

      @hoare_intake %Hoare.Intake{
        transition: %Hoare.Transition{
          from: unquote(Keyword.fetch!(opts, :from)),
          to: unquote(Keyword.fetch!(opts, :to)),
          preloads: unquote(Keyword.get(opts, :preloads, []))
        },
        schema: unquote(Keyword.fetch!(opts, :schema)),
        key: unquote(Keyword.fetch!(opts, :key)),
        identity: unquote(Keyword.get(opts, :identity, []))
      }

      defstruct [:record, :state | unquote(Keyword.get(opts, :ctx, []))]

      @impl Hoare.Transition
      def guards, do: []

      @impl Hoare.Transition
      def effects, do: []

      defoverridable guards: 0, effects: 0

      @spec check(Hoare.Transition.ctx()) :: {:ok, Hoare.Transition.ctx()} | {:error, term()}
      def check(ctx), do: Hoare.Transition.check(intake().transition, ctx)

      @spec run(Hoare.Transition.ctx(), Hoare.Transition.body(), Hoare.Intake.opts()) ::
              {:ok, Hoare.Transition.ctx()} | {:error, term()}
      def run(ctx, body, opts), do: Hoare.Intake.run(intake(), ctx, body, opts)

      @spec preloads() :: [term()]
      def preloads, do: Hoare.Intake.preloads(intake())
    end
  end

  defmacro __before_compile__(env) do
    stranded =
      if Module.defines?(env.module, {:stranded, 2}, :def),
        do: quote(do: &__MODULE__.stranded/2)

    quote do
      @spec intake() :: Hoare.Intake.t()
      def intake do
        intake = @hoare_intake

        transition = %{
          intake.transition
          | guards: guards(),
            effects: effects(),
            stranded: unquote(stranded)
        }

        %{intake | transition: transition}
      end
    end
  end

  @doc "What the created record is read with: the `to` state's preloads, then the intake's own."
  @spec preloads(t()) :: [term()]
  def preloads(%Intake{transition: %Transition{to: to, preloads: own}}),
    do: State.preloads(to) ++ own

  @doc """
  Runs the intake end to end: guards, then effects, then the keyed commit.

  The payload is the context's `record` and the matched payload state its
  `state`; on success the context comes back with `record` replaced by the
  record that arrived.
  """
  @spec run(t(), Transition.ctx(), Transition.body(), opts()) ::
          {:ok, Transition.ctx()} | {:error, term()}
  def run(%Intake{transition: transition} = intake, ctx, body, opts)
      when is_function(body, 1) do
    Transition.discharge(transition, ctx, &commit(intake, &1, body, &2, opts))
  end

  @doc """
  Commits in one locked transaction, keyed on the payload's natural key.

  Reads by the key, runs `body` when nothing is there, and asserts `to` on
  the record read back; a row already under the key is the same payload
  again, as `identity` decides. See the module documentation for the whole
  rule.
  """
  @spec commit(t(), Transition.ctx(), Transition.body(), boolean(), opts()) ::
          {:ok, Store.subject()} | {:error, term()}
  def commit(%Intake{schema: schema} = intake, %{state: state} = ctx, body, converges?, opts) do
    store = Keyword.fetch!(opts, :store)
    key = key(intake, state)
    lock = Keyword.get(opts, :lock, {schema, key})

    store.transact_with_lock(lock, fn ->
      case read(intake, store, key) do
        {:error, :not_found} -> create(intake, store, key, ctx, body)
        {:ok, found} -> converged(intake, found, state, converges?)
      end
    end)
  end

  defp create(intake, store, key, ctx, body) do
    with {:ok, _} <- body.(ctx), do: arrived!(intake, store, key)
  end

  defp arrived!(%Intake{schema: schema, transition: %Transition{to: to}} = intake, store, key) do
    case read(intake, store, key) do
      {:ok, record} -> match!(to, record, schema)
      {:error, :not_found} -> raise "the body created no #{inspect(schema)} under #{inspect(key)}"
    end
  end

  defp match!(to, record, schema) do
    case State.match(to, record) do
      {:ok, _} ->
        {:ok, record}

      {:error, reason} ->
        raise "the created #{inspect(schema)} is not #{inspect(to)}: #{inspect(reason)}"
    end
  end

  # Identity is what tells a replay from a collision; an effect left behind
  # makes even a replay an error, so its undos run.
  defp converged(%Intake{identity: identity}, found, state, converges?) do
    cond do
      not Enum.all?(identity, &(Map.fetch!(found, &1) == witness!(state, &1))) ->
        {:error, :conflict}

      converges? ->
        {:ok, found}

      true ->
        {:error, :already_exists}
    end
  end

  defp read(%Intake{schema: schema} = intake, store, key),
    do: store.read_by(schema, key, preloads(intake))

  defp key(%Intake{key: key}, state), do: Enum.map(key, &{&1, witness!(state, &1)})

  defp witness!(%module{} = state, field) do
    case Map.fetch(state, field) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{inspect(module)} witnesses no #{inspect(field)}"
    end
  end
end
