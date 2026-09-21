# Changelog

## 0.2.0 (2026-09-21)

### Breaking

- `Hoare.Store`: `fetch/2` is replaced by `read/3`, which takes the preloads
  the commit needs.
- The commit re-reads the record with the transition's preloads and runs the
  whole check on it under the lock, properties and guards, not the status
  alone. Guards therefore run twice and must be functions of the context. The
  body receives the re-checked context, the status is written on the record
  just read, and `to` is asserted on a second read rather than on what the
  caller loaded.

### Added

- `preloads/0` on `Hoare.State` (optional) and `preloads` on
  `Hoare.Transition`; `Hoare.Transition.preloads/1` is the one list the
  caller's fetch and the commit's read share.
- `stranded` on a transition: told when a run fails after a bare effect.
- `Hoare.Transition.commit_error/0` and `error/1` types; `from_statuses/1`.
- `use Hoare.State` and `Hoare.State.defstate/3`, which declares several
  states in one module; `:missing` defaults to `:not_<status>` and the
  struct's type is `t/0`.
- `use Hoare.Transition`: the declaration as a module, with `transition/0`,
  `check/1`, `run/3`, `preloads/0` and `from_statuses/0`.
- `Hoare.Result.ensure/2` lifts a predicate into an arrow.
- `Hoare.Graph`: edges, states and a Mermaid diagram from transition modules.
- `Hoare.Store.Memory`: a process-local store for tests.
- `.formatter.exs` exports `defstate` without parentheses.

### Fixed

- An undo that fails no longer stops the older undos from running; the first
  failure is raised once all have had their turn.

## 0.1.0 (2026-09-20)

Initial release.

- `Hoare.State`: a behaviour naming the status that tags a record, the reason
  when it does not, and the properties that refine it into a struct of
  witnesses; `match/2` and `match_any/2` build that struct or say why not.
- `Hoare.Transition`: `from` and `to` states, guards and effects composed as
  Kleisli arrows; `run/4` checks, performs the effects, then commits through
  the store in one locked transaction with a `from` re-check and a `to`
  assertion. Bare effects are idempotent and retried by re-running; effects
  paired with an undo are reverted newest first when anything after them
  fails. A record already in `to` converges only when every completed effect
  was bare.
- `Hoare.Store`: the three operations the commit needs, `transact_with_lock/2`,
  `fetch/2` and `update/1`.
- `Hoare.Result`: `bind/2`, `kleisli/1`, `tap_ok/2`, `tap_error/2`,
  `map_error/2` over tagged tuples.
