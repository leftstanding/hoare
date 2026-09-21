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
    def read(schema, id, preloads) do
      send(self(), {:read, preloads})
      Memory.read(schema, id, preloads)
    end

    @impl Hoare.Store
    def update({record, _attrs} = changeset) do
      send(self(), {:updated, record})
      Memory.update(changeset)
    end
  end

  defmodule A do
    @behaviour State
    defstruct [:record]
    def status, do: :A
    def missing, do: :not_a
    def properties, do: []
    def preloads, do: [:from_a]
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

  defmodule Bare do
    use Hoare.Transition, from: [A], to: B
  end

  defmodule Declared do
    use Hoare.Transition, from: [A], to: B, ctx: [:guarded, :performed], preloads: [:own]

    @impl Hoare.Transition
    def guards, do: [&{:ok, %{&1 | guarded: true}}]

    @impl Hoare.Transition
    def effects, do: [&{:ok, %{&1 | performed: true}}]

    @impl Hoare.Transition
    def stranded(ctx, reason), do: send(self(), {:stranded, ctx, reason})
  end

  @a_to_b %Transition{from: [A], to: B}
  @opts [store: FakeStore]

  setup do
    FakeStore.stored(%Record{id: 1, status: :A, witness: "seen"})
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

  describe "preloads/1" do
    test "concatenates the from states', the to state's and the transition's own" do
      assert Transition.preloads(%{@a_to_b | preloads: [own: :nested]}) ==
               [:from_a, own: :nested]
    end

    test "is empty when nothing declares any" do
      assert Transition.preloads(%Transition{from: [B], to: B}) == []
    end
  end

  describe "run/4" do
    test "runs guards, effects and body in order and returns the context on the committed record" do
      transition = %{
        @a_to_b
        | guards: [&{:ok, Map.put(&1, :guarded, true)}],
          effects: [&{:ok, Map.put(&1, :performed, &1.guarded)}]
      }

      body = fn ctx ->
        assert %{guarded: true, performed: true} = ctx
        {:ok, ctx}
      end

      assert {:ok,
              %{
                record: %Record{id: 1, status: :B, witness: "seen"},
                guarded: true,
                performed: true
              }} =
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
      FakeStore.stored(%Record{id: 1, status: :A, witness: nil})

      assert_raise RuntimeError, ~r/not .*TransitionTest.B: :no_witness/, fn ->
        run(@a_to_b, ctx(:A))
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
      Hoare.Store.Memory.delete(Record, 1)

      assert run(@a_to_b, ctx(:A), fn _ -> flunk("body ran") end) == {:error, :not_found}
    end

    test "checks the fresh record again under the lock, guards included" do
      FakeStore.stored(%Record{id: 1, status: :A, witness: "changed"})

      transition = %{
        @a_to_b
        | guards: [
            fn
              %{record: %Record{witness: "seen"}} = ctx -> {:ok, ctx}
              _ctx -> {:error, :witness_changed}
            end
          ]
      }

      assert run(transition, ctx(:A), fn _ -> flunk("body ran") end) ==
               {:error, :witness_changed}
    end

    test "runs the body and the status write on the fresh record" do
      fresh = FakeStore.stored(%Record{id: 1, status: :A, witness: "fresh"})

      body = fn ctx ->
        assert ctx.record == fresh
        assert ctx.state == %A{record: fresh}
        {:ok, ctx}
      end

      assert {:ok, %{record: %Record{status: :B, witness: "fresh"}}} = run(@a_to_b, ctx(:A), body)
      assert_received {:updated, ^fresh}
    end

    test "asserts the to state on what the body left in the store" do
      body = fn _ctx -> {:ok, FakeStore.stored(%Record{id: 1, status: :A, witness: nil})} end

      assert_raise RuntimeError, ~r/:no_witness/, fn -> run(@a_to_b, ctx(:A), body) end
    end

    test "reads with the transition's preloads" do
      assert {:ok, _} = run(%{@a_to_b | preloads: [:own]}, ctx(:A))
      assert_received {:read, [:from_a, :own]}
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

  describe "run/4 with a failing undo" do
    test "still undoes the older effects, then raises the failure" do
      transition = %{
        @a_to_b
        | effects: [
            {&{:ok, &1}, fn _ -> tap(:ok, fn _ -> send(self(), :undo_older) end) end},
            {&{:ok, &1}, fn _ -> raise "carrier down" end}
          ]
      }

      assert_raise RuntimeError, "carrier down", fn ->
        run(transition, ctx(:A), fn _ -> {:error, :commit_failed} end)
      end

      assert_received :undo_older
    end
  end

  describe "run/4 with a stranded hook" do
    defp stranded(ctx, reason), do: send(self(), {:stranded, ctx, reason})

    test "reports a commit that fails after a bare effect" do
      transition = %{
        @a_to_b
        | effects: [&{:ok, Map.put(&1, :voided, true)}],
          stranded: &stranded/2
      }

      assert run(transition, ctx(:A), fn _ -> {:error, :commit_failed} end) ==
               {:error, :commit_failed}

      assert_received {:stranded, %{voided: true}, :commit_failed}
    end

    test "reports a later effect that fails after a bare effect" do
      transition = %{
        @a_to_b
        | effects: [&{:ok, &1}, fn _ -> {:error, :effect_failed} end],
          stranded: &stranded/2
      }

      assert run(transition, ctx(:A)) == {:error, :effect_failed}
      assert_received {:stranded, _ctx, :effect_failed}
    end

    test "stays quiet when every completed effect was undone" do
      transition = %{
        @a_to_b
        | effects: [{&{:ok, &1}, fn _ -> :ok end}],
          stranded: &stranded/2
      }

      assert run(transition, ctx(:A), fn _ -> {:error, :commit_failed} end) ==
               {:error, :commit_failed}

      refute_received {:stranded, _, _}
    end

    test "stays quiet when a guard refuses or a concurrent run converges" do
      refused = %{
        @a_to_b
        | guards: [fn _ -> {:error, :blocked} end],
          effects: [&{:ok, &1}],
          stranded: &stranded/2
      }

      assert run(refused, ctx(:A)) == {:error, :blocked}

      FakeStore.stored(%Record{id: 1, status: :B, witness: "seen"})
      assert {:ok, _} = run(%{refused | guards: []}, ctx(:A))

      refute_received {:stranded, _, _}
    end
  end

  describe "use Hoare.Transition" do
    test "defaults to no guards, no effects and no stranded hook" do
      assert Bare.transition() == @a_to_b
      assert %Bare{} == %Bare{record: nil, state: nil}
    end

    test "assembles the declaration from the options and the callbacks" do
      assert %Transition{from: [A], to: B, guards: [_], effects: [_], preloads: [:own]} =
               Declared.transition()

      assert Declared.preloads() == [:from_a, :own]
      assert Declared.from_statuses() == [:A]
    end

    test "checks and runs on its own context struct" do
      record = %Record{id: 1, status: :A, witness: "seen"}

      assert {:ok, %Declared{guarded: true, performed: nil}} =
               Declared.check(%Declared{record: record})

      assert {:ok, %Declared{record: %Record{status: :B}, guarded: true, performed: true}} =
               Declared.run(%Declared{record: record}, &{:ok, &1}, @opts)
    end

    test "wires stranded/2 when the module defines it" do
      record = %Record{id: 1, status: :A, witness: "seen"}

      assert Declared.run(%Declared{record: record}, fn _ -> {:error, :commit_failed} end, @opts) ==
               {:error, :commit_failed}

      assert_received {:stranded, %Declared{performed: true}, :commit_failed}
    end
  end
end
