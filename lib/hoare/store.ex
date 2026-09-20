defmodule Hoare.Store do
  @moduledoc """
  What a transition's commit needs from the datastore.

  Three operations: a transaction serialised per record, a re-read under it,
  and the status write. An `Ecto.Repo` satisfies `update/1` as is and needs
  the other two added; a repo that already has them declares the behaviour:

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
        @behaviour Hoare.Store

        @impl Hoare.Store
        def transact_with_lock(lock, fun), do: transaction(fn -> with_advisory_lock(lock, fun) end)

        @impl Hoare.Store
        def fetch(schema, id), do: if(record = get(schema, id), do: {:ok, record}, else: {:error, :not_found})
      end

  The record's schema supplies `changeset/2`, which `update/1` receives with the
  new status. In tests a module that keeps records in memory is enough.
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

  @callback fetch(schema :: module(), id :: term()) :: {:ok, subject()} | {:error, :not_found}

  @callback update(changeset :: term()) :: {:ok, subject()} | {:error, term()}
end
