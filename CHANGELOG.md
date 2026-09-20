# Changelog

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
