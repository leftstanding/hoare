# Hoare

[![CI](https://github.com/leftstanding/hoare/actions/workflows/ci.yml/badge.svg)](https://github.com/leftstanding/hoare/actions/workflows/ci.yml)
[![Hex Version](https://img.shields.io/hexpm/v/hoare.svg)](https://hex.pm/packages/hoare)
[![License](https://img.shields.io/hexpm/l/hoare.svg)](https://github.com/leftstanding/hoare/blob/master/LICENSE)

Declared state transitions as pre/post contracts.

A transition names the states it leaves and the state it reaches, the guards
that must hold, and the effects it performs on the way. `{from, guards} body
{to}` is a Hoare triple; `Hoare.Transition.run/4` discharges it and keeps one
law: a run ends in `to` or leaves the record in `from`, never between.

```
check   from ▸ guards            pure, on the resolved record
perform effects                  IO; bare = idempotent, {run, undo} = reverted on failure
commit  lock ▸ re-read ▸ body ▸ write to ▸ assert to     one transaction
```

## Installation

```elixir
def deps do
  [
    {:hoare, "~> 0.1"}
  ]
end
```

## States

A state is a module: the status that tags a record, the reason when it does
not, and the properties that refine the tag and extract witnesses.

```elixir
defmodule PendingUnpack do
  @behaviour Hoare.State
  defstruct [:record, :package]

  def status, do: :PENDING_UNPACK
  def missing, do: :not_pending_unpack
  def properties, do: [&single_package/1]

  defp single_package(%{record: %{packages: [package]}} = state), do: {:ok, %{state | package: package}}
  defp single_package(%{record: %{packages: []}}), do: {:error, :no_packages}
  defp single_package(_), do: {:error, :multiple_packages}
end
```

`Hoare.State.match/2` builds the struct or says why the record is not in that
state. A state entered by one transition is the same module another leaves
from, so the graph is nominal and inspectable.

## Transitions

```elixir
defmodule Repack do
  defstruct [:record, :state, :label]

  def transition do
    %Hoare.Transition{
      from: [PendingUnpack],
      to: Packed,
      effects: [{&purchase_label/1, &release_label/1}]
    }
  end

  defp purchase_label(ctx), do: with({:ok, label} <- Carrier.buy(ctx.state.package), do: {:ok, %{ctx | label: label}})
  defp release_label(%{label: label}), do: :ok = Carrier.release(label)
end
```

The context is any struct with `record` and `state` keys. The module owning
the records supplies the body of the commit and the store:

```elixir
Hoare.Transition.run(Repack.transition(), %Repack{record: order}, &write_package/1, store: Repo)
# {:ok, %Repack{record: %Order{status: :PACKED}, ...}} | {:error, reason}
```

`commit/5` takes the store's lock on `{schema, id}` (or `opts[:lock]`), re-reads
the record and refuses it unless still tagged by a `from` state, runs the
body, writes `to`'s status through the schema's `changeset/2`, and asserts `to`
before the transaction closes. A record already in `to` is a concurrent run:
it converges as `{:ok, record}` when every completed effect was bare, and is
`{:error, :status_changed}` when one must be undone.

## Store

`Hoare.Store` is the three operations the commit needs: `transact_with_lock/2`,
`fetch/2`, `update/1`. An Ecto repo supplies the last as is and declares the
other two.

## Results

`Hoare.Result` holds the few combinators the runner is built from: `bind/2`,
`kleisli/1`, `tap_ok/2`, `tap_error/2`, `map_error/2`. Tagged tuples
throughout; nothing is wrapped.
