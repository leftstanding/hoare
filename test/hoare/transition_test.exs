defmodule Hoare.TransitionTest do
  use ExUnit.Case, async: true

  alias Hoare.State
  alias Hoare.Transition

  # A schema stands in for an Ecto one: `changeset/2` is whatever the store's
  # `update/1` accepts; here the pending changes ride along as a tuple.
  defmodule Record do
    defstruct [:id, :status, :witness]

    def changeset(record, attrs), do: {record, attrs}
  end

  # The store the commit runs against: `stored/1` is what the locked re-read
  # returns; `update/1` applies the changes in memory.
  defmodule FakeStore do
    @behaviour Hoare.Store

    def stored(record), do: Process.put(:stored, record)

    @impl Hoare.Store
    def transact_with_lock(lock, fun) do
      send(self(), {:locked, lock})
      fun.()
    end

    @impl Hoare.Store
    def fetch(Record, id) do
      case Process.get(:stored) do
        %Record{id: ^id} = record -> {:ok, record}
        _ -> {:error, :not_found}
      end
    end

    @impl Hoare.Store
    def update({record, attrs}), do: {:ok, struct!(record, attrs)}
  end

  defmodule A do
    @behaviour State
    defstruct [:record]
    def status, do: :A
    def missing, do: :not_a
    def properties, do: []
  end

  defmodule B do
    @behaviour State
    defstruct [:record, :witness]
    def status, do: :B
    def missing, do: :not_b
    def properties, do: [&witness/1]

    defp witness(%B{record: %{witness: nil}}), do: {:error, :no_witness}
    defp witness(%B{record: %{witness: witness}} = state), do: {:ok, %{state | witness: witness}}
  end

  @a_to_b %Transition{from: [A], to: B}
  @opts [store: FakeStore]

  setup do
    FakeStore.stored(%Record{id: 1, status: :A})
    :ok
  end

  defp ctx(status, witness \\ "seen"),
    do: %{record: %Record{id: 1, status: status, witness: witness}, state: nil}

  defp run(transition, ctx, body \\ &{:ok, &1}), do: Transition.run(transition, ctx, body, @opts)

  describe "check/2" do
    test "matches from into state, then threads the context through every guard" do
      transition = %{
        @a_to_b
        | guards: [&{:ok, Map.put(&1, :first, true)}, &{:ok, Map.put(&1, :second, true)}]
      }

      assert {:ok, %{state: %A{record: %Record{status: :A}}, first: true, second: true}} =
               Transition.check(transition, ctx(:A))
    end

    test "returns the from state's missing reason before any guard runs" do
      transition = %{@a_to_b | guards: [fn _ -> flunk("guard ran") end]}

      assert Transition.check(transition, ctx(:B)) == {:error, :not_a}
    end

    test "returns the first failing guard's reason" do
      transition = %{
        @a_to_b
        | guards: [&{:ok, &1}, fn _ -> {:error, :blocked} end, fn _ -> {:error, :unreached} end]
      }

      assert Transition.check(transition, ctx(:A)) == {:error, :blocked}
    end
  end

  describe "run/4" do
    test "runs guards, effects and body in order and returns the context on the committed record" do
      transition = %{
        @a_to_b
        | guards: [&{:ok, Map.put(&1, :trail, [:guard])}],
          effects: [&{:ok, Map.update!(&1, :trail, fn t -> [:effect | t] end)}]
      }

      body = fn ctx ->
        assert ctx.trail == [:effect, :guard]
        {:ok, ctx}
      end

      assert {:ok,
              %{record: %Record{id: 1, status: :B, witness: "seen"}, trail: [:effect, :guard]}} =
               run(transition, ctx(:A), body)
    end

    test "a failing guard skips the effects and the commit" do
      transition = %{
        @a_to_b
        | guards: [fn _ -> {:error, :blocked} end],
          effects: [fn _ -> flunk("effect ran") end]
      }

      assert run(transition, ctx(:A), fn _ -> flunk("body ran") end) == {:error, :blocked}
      refute_received {:locked, _}
    end

    test "a failing effect skips the commit" do
      transition = %{@a_to_b | effects: [fn _ -> {:error, :void_failed} end]}

      assert run(transition, ctx(:A), fn _ -> flunk("body ran") end) == {:error, :void_failed}
      refute_received {:locked, _}
    end

    test "raises inside the transaction when the committed record is not in the to state" do
      assert_raise RuntimeError, ~r/not .*TransitionTest.B: :no_witness/, fn ->
        run(@a_to_b, ctx(:A, nil))
      end
    end

    test "requires a store" do
      assert_raise KeyError, fn -> Transition.run(@a_to_b, ctx(:A), &{:ok, &1}, []) end
    end
  end

  describe "commit/5" do
    test "locks on the record by default and on the given lock otherwise" do
      assert {:ok, _} = run(@a_to_b, ctx(:A))
      assert_received {:locked, {Record, 1}}

      assert {:ok, _} =
               Transition.run(@a_to_b, ctx(:A), &{:ok, &1}, store: FakeStore, lock: :mine)

      assert_received {:locked, :mine}
    end

    test "returns the body's error without writing the status" do
      assert run(@a_to_b, ctx(:A), fn _ -> {:error, :body_failed} end) == {:error, :body_failed}
    end

    test "refuses a record that left the from states under it" do
      FakeStore.stored(%Record{id: 1, status: :C})

      assert run(@a_to_b, ctx(:A), fn _ -> flunk("body ran") end) == {:error, :status_changed}
    end

    test "refuses a record that disappeared under it" do
      FakeStore.stored(nil)

      assert run(@a_to_b, ctx(:A), fn _ -> flunk("body ran") end) == {:error, :not_found}
    end

    test "converges on a record already in the to state when every effect was idempotent" do
      FakeStore.stored(%Record{id: 1, status: :B})
      transition = %{@a_to_b | effects: [&{:ok, &1}]}

      assert {:ok, %{record: %Record{status: :B}}} =
               run(transition, ctx(:A), fn _ -> flunk("body ran") end)
    end

    test "refuses a record already in the to state when an effect must be undone" do
      FakeStore.stored(%Record{id: 1, status: :B})

      transition = %{
        @a_to_b
        | effects: [{&{:ok, &1}, fn _ -> tap(:ok, fn _ -> send(self(), :undone) end) end}]
      }

      assert run(transition, ctx(:A), fn _ -> flunk("body ran") end) == {:error, :status_changed}
      assert_received :undone
    end
  end

  describe "run/4 with undoable effects" do
    test "undoes completed effects newest first when the commit fails" do
      transition = %{
        @a_to_b
        | effects: [
            {&{:ok, Map.put(&1, :first, true)},
             fn _ -> tap(:ok, fn _ -> send(self(), :undo_first) end) end},
            &{:ok, Map.put(&1, :idempotent, true)},
            {&{:ok, Map.put(&1, :second, true)},
             fn ctx -> tap(:ok, fn _ -> send(self(), {:undo_second, ctx}) end) end}
          ]
      }

      assert run(transition, ctx(:A), fn _ -> {:error, :commit_failed} end) ==
               {:error, :commit_failed}

      assert_received {:undo_second, %{first: true, idempotent: true, second: true}}
      assert_received :undo_first
    end

    test "undoes completed effects when a later effect fails" do
      transition = %{
        @a_to_b
        | effects: [
            {&{:ok, &1}, fn _ -> tap(:ok, fn _ -> send(self(), :undone) end) end},
            fn _ -> {:error, :effect_failed} end
          ]
      }

      assert run(transition, ctx(:A), fn _ -> flunk("body ran") end) == {:error, :effect_failed}
      assert_received :undone
    end

    test "leaves the effects alone when the commit succeeds" do
      transition = %{@a_to_b | effects: [{&{:ok, &1}, fn _ -> flunk("undone") end}]}

      assert {:ok, %{record: %Record{status: :B}}} = run(transition, ctx(:A))
    end

    test "raises when an undo does not succeed" do
      transition = %{@a_to_b | effects: [{&{:ok, &1}, fn _ -> {:error, :stuck} end}]}

      assert_raise MatchError, fn ->
        run(transition, ctx(:A), fn _ -> {:error, :commit_failed} end)
      end
    end
  end
end
