defmodule Hoare.IntakeTest do
  use ExUnit.Case, async: true

  alias Hoare.Intake
  alias Hoare.State
  alias Hoare.Transition

  # A schema stands in for an Ecto one, as in `Hoare.TransitionTest`.
  defmodule Record do
    defstruct [:id, :status, :number, :account_id, :external_id]

    def changeset(record, attrs), do: {record, attrs}
  end

  # `Hoare.Store.Memory`, reporting what the commit asked of it.
  defmodule FakeStore do
    @behaviour Hoare.Store

    alias Hoare.Store.Memory

    defdelegate stored(record), to: Memory, as: :put

    @impl Hoare.Store
    def transact_with_lock(lock, fun) do
      send(self(), {:locked, lock})
      Memory.transact_with_lock(lock, fun)
    end

    @impl Hoare.Store
    defdelegate read(schema, id, preloads), to: Memory

    @impl Hoare.Store
    def read_by(schema, key, preloads) do
      send(self(), {:read_by, key, preloads})
      Memory.read_by(schema, key, preloads)
    end

    @impl Hoare.Store
    defdelegate update(changeset), to: Memory
  end

  # The payload is a shape, defined but not yet in the system: an untagged
  # state over the params, whose properties resolve what the key needs.
  defmodule Payload do
    use State, witnesses: [:number, :account_id, :external_id]

    @impl State
    def properties, do: [&numbered/1, &accounted/1]

    defp numbered(%Payload{record: %{"number" => number, "external_id" => id}} = state),
      do: {:ok, %{state | number: number, external_id: id}}

    defp numbered(%Payload{}), do: {:error, :no_number}

    defp accounted(%Payload{record: %{"account" => "a-" <> id}} = state),
      do: {:ok, %{state | account_id: String.to_integer(id)}}

    defp accounted(%Payload{}), do: {:error, :no_account}
  end

  defmodule Arrived do
    use State, status: :ARRIVED, preloads: [:lines]
  end

  defmodule Receive do
    use Hoare.Intake,
      from: [Payload],
      to: Arrived,
      schema: Record,
      key: [:number, :account_id],
      identity: [:external_id],
      ctx: [:performed]

    @impl Hoare.Transition
    def effects, do: [&{:ok, %{&1 | performed: true}}]

    @impl Hoare.Transition
    def stranded(ctx, reason), do: send(self(), {:stranded, ctx, reason})
  end

  @intake %Intake{
    transition: %Transition{from: [Payload], to: Arrived},
    schema: Record,
    key: [:number, :account_id],
    identity: [:external_id]
  }

  @opts [store: FakeStore]

  describe "check/2" do
    test "matches the payload state and fills its witnesses" do
      assert {:ok, %{state: %Payload{number: "n-1", account_id: 7, external_id: "x-1"}}} =
               Transition.check(@intake.transition, ctx())
    end

    test "reports the property that the payload does not satisfy" do
      assert Transition.check(@intake.transition, %{record: %{"account" => "a-7"}, state: nil}) ==
               {:error, :no_number}
    end
  end

  describe "preloads/1" do
    test "takes the to state's and the intake's own, and not the payload's" do
      assert Intake.preloads(@intake) == [:lines]
      assert Intake.preloads(put_in(@intake.transition.preloads, [:own])) == [:lines, :own]
    end
  end

  describe "run/4 when nothing is under the key" do
    test "runs the body and returns the context on the record it created" do
      assert {:ok, %{record: %Record{id: 1, status: :ARRIVED, number: "n-1", account_id: 7}}} =
               run(ctx(), &insert/1)
    end

    test "locks on the schema and the key by default, and on the given lock otherwise" do
      assert {:ok, _} = run(ctx(), &insert/1)
      assert_received {:locked, {Record, [number: "n-1", account_id: 7]}}

      assert {:ok, _} = Intake.run(@intake, ctx(), &insert/1, store: FakeStore, lock: :mine)
      assert_received {:locked, :mine}
    end

    test "reads by the key with the to state's preloads" do
      assert {:ok, _} = run(ctx(), &insert/1)
      assert_received {:read_by, [number: "n-1", account_id: 7], [:lines]}
    end

    test "returns the body's error, having created nothing" do
      assert run(ctx(), fn _ -> {:error, :body_failed} end) == {:error, :body_failed}
      assert FakeStore.read_by(Record, [number: "n-1"], []) == {:error, :not_found}
    end

    test "raises when the body created no record under the key" do
      body = fn _ctx -> {:ok, FakeStore.stored(%Record{id: 1, number: "elsewhere"})} end

      assert_raise RuntimeError, ~r/created no .*Record under \[number: "n-1"/, fn ->
        run(ctx(), body)
      end
    end

    test "raises when the record the body created is not in the to state" do
      body = fn ctx -> ctx |> insert() |> elem(1) |> Map.put(:status, :OTHER) |> stored() end

      assert_raise RuntimeError, ~r/is not .*Arrived: :not_arrived/, fn -> run(ctx(), body) end
    end
  end

  describe "run/4 when a record is under the key" do
    setup do
      FakeStore.stored(%Record{
        id: 1,
        status: :ARRIVED,
        number: "n-1",
        account_id: 7,
        external_id: "x-1"
      })

      :ok
    end

    test "converges on it without running the body" do
      assert {:ok, %{record: %Record{id: 1}}} = run(ctx(), fn _ -> flunk("body ran") end)
    end

    test "returns it as it stands, wherever it has since moved" do
      moved =
        FakeStore.stored(%Record{
          id: 1,
          status: :SHIPPED,
          number: "n-1",
          account_id: 7,
          external_id: "x-1"
        })

      assert {:ok, %{record: ^moved}} = run(ctx(), fn _ -> flunk("body ran") end)
    end

    test "refuses a record the key finds but the identity does not claim" do
      assert run(ctx(%{"external_id" => "x-2"}), fn _ -> flunk("body ran") end) ==
               {:error, :conflict}
    end

    test "identifies by the key alone when no identity is declared" do
      intake = %{@intake | identity: []}

      assert {:ok, %{record: %Record{external_id: "x-1"}}} =
               Intake.run(intake, ctx(%{"external_id" => "x-2"}), &insert/1, @opts)
    end

    test "refuses it, undoing what ran, when an effect must be undone" do
      undoable = {&{:ok, &1}, fn _ -> tap(:ok, fn _ -> send(self(), :undone) end) end}
      intake = put_in(@intake.transition.effects, [undoable])

      assert Intake.run(intake, ctx(), fn _ -> flunk("body ran") end, @opts) ==
               {:error, :already_exists}

      assert_received :undone
    end
  end

  describe "run/4 with a key the payload does not resolve" do
    test "raises rather than keying on nothing" do
      intake = %{@intake | key: [:mall_id]}

      assert_raise ArgumentError, ~r/Payload witnesses no :mall_id/, fn ->
        Intake.run(intake, ctx(), &insert/1, @opts)
      end
    end
  end

  describe "use Hoare.Intake" do
    test "assembles the intake from the options and the callbacks" do
      assert %Intake{
               schema: Record,
               key: [:number, :account_id],
               identity: [:external_id],
               transition: %Transition{from: [Payload], to: Arrived, effects: [_], stranded: fun}
             } = Receive.intake()

      assert is_function(fun, 2)
    end

    test "runs the effects, then the commit, on the context struct" do
      body = fn ctx ->
        assert %Receive{performed: true, state: %Payload{}} = ctx
        insert(ctx)
      end

      assert {:ok, %Receive{record: %Record{status: :ARRIVED}, performed: true}} =
               Receive.run(%Receive{record: params()}, body, @opts)
    end

    test "reports what preloads the created record is read with" do
      assert Receive.preloads() == [:lines]
    end
  end

  defp params(overrides \\ %{}),
    do: Map.merge(%{"number" => "n-1", "account" => "a-7", "external_id" => "x-1"}, overrides)

  defp ctx(overrides \\ %{}), do: %{record: params(overrides), state: nil}

  defp run(ctx, body), do: Intake.run(@intake, ctx, body, @opts)

  defp insert(%{state: %Payload{} = payload}) do
    stored(%Record{
      id: 1,
      status: :ARRIVED,
      number: payload.number,
      account_id: payload.account_id,
      external_id: payload.external_id
    })
  end

  defp stored(record), do: {:ok, FakeStore.stored(record)}
end
