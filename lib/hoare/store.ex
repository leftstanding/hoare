defmodule Hoare.Store do
  @moduledoc """
  What a transition's commit needs from the datastore.

  Three operations: a transaction serialised per record, a preloaded read
  under it, and the status write. An `Ecto.Repo` satisfies `update/1` as is
  and needs the other two added:

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
        @behaviour Hoare.Store

        @impl Hoare.Store
        def transact_with_lock(lock, fun) do
          transact(fn ->
            query!("SELECT pg_advisory_xact_lock($1)", [:erlang.phash2(lock)])
            fun.()
          end)
        end

        @impl Hoare.Store
        def read(schema, id, preloads) do
          if record = get(schema, id),
            do: {:ok, preload(record, preloads)},
            else: {:error, :not_found}
        end
      end

  The record's schema supplies `changeset/2`, which `update/1` receives with the
  new status. `Hoare.Store.Memory` is the store for tests.
  """

  @type subject :: %{
          :__struct__ => module(),
          :id => term(),
          :status => atom(),
          optional(atom()) => term()
        }
  @type result :: {:ok, term()} | {:error, term()}

  @doc "Runs `fun` inside a transaction that no other holder of `lock` shares; its result is the return."
  @callback transact_with_lock(lock :: term(), fun :: (-> result())) :: result()

  @doc "Reads the record by id with `preloads` loaded, inside the caller's transaction."
  @callback read(schema :: module(), id :: term(), preloads :: [term()]) ::
              {:ok, subject()} | {:error, :not_found}

  @callback update(changeset :: term()) :: {:ok, subject()} | {:error, term()}
end
