# Task: Fix the recurring flaky `spec/cli_serve_debug_env_spec.rb` + aux-port bind robustness

Outcome: kill the serve-debug flake at the correct layer, prove it on CI with a
repeat loop, fix the auxiliary AI/test-port bind-rescue fragility across the
frameworks that share it, all with real (no-mock) regression tests.

## Scope
- [x] Confirm the traced root cause against the Ruby code + empirically
- [x] Aux-port bind: broaden rescue (log-loud + degrade, never crash) — Ruby
- [ ] Aux-port bind: Node parity (log-loud any error, null the dangling server)
- [x] Harness: bound the `/__dev` poll by the same generous deadline as `/health`
- [ ] Regression test: aux-port non-EADDRINUSE bind degrades, main server serves (Ruby)
- [ ] Regression test: aux-port parity (Node)
- [ ] Verify on CI, loop the serve spec 5+ times, mutation-check the source fix

## Root cause — CONFIRMED NOT the traced "/__dev mounts after /health" race (Ruby)
The traced theory (PR #84/#91): `/health` comes up before the debug-gated `/__dev`
"routes finish mounting", so a probe catches a transient 404. **This does not hold
in Ruby.** `/__dev` is NOT a mounted route — it is a per-request dispatch stage
(`dispatch_pipeline.rb` `dev_routes` → `DevAdmin.handle_request`) gated purely on
`ENV["TINA4_DEBUG"]`, read fresh each request (`dev_admin.rb:338 enabled?`). The env
is loaded in `initialize!` (`tina4.rb:463`) BEFORE the socket binds/accepts
(`webserver.rb#start`). So socket-up ⇒ `/__dev` already answers (debug on) — a
structural guarantee, not a race. Evidence:
- 240 real boots under 6× parallel contention: 0 inversions — `/__dev` answered
  the instant `/health` did, every time.
- A debug-ON dispatching server can only return 200 (or a 403 host/origin gate)
  for `/__dev`, never a settled 404; `/health`=200 proves the app dispatches.
- CI runs `bundle exec rspec` single-process (no parallel_tests); matrix jobs get
  separate runners → no port-collision from a debug-off neighbour.

Therefore the PREFERRED source fix (register `/__dev` before bind / readiness
signal) has nothing to reorder — the guarantee already holds. The residual
fragility is in the HARNESS: `poll_status(settle_within: 5)` used a FIXED 5 s
window decoupled from the generous 30 s `/health` wait, so under CI starvation a
burst of transient connection failures (get→nil) can expire the window and return
nil/stale → the example raises. Fix = step 3: bound the `/__dev` poll by the same
generous deadline (retry connection failures; return the first real non-404 the
instant it appears; confirm a settled 404 by a short stable window).

## Parity (readiness race a / aux-port rescue b)
| Framework | (a) /__dev readiness | (b) aux-port bind failure |
|-----------|----------------------|---------------------------|
| Python ref | env-gated stage — no race ✅ | broad `except OSError` degrade ✅ |
| PHP | mounted before bind — no race ✅ | FALSE-return + `\Throwable` degrade ✅ |
| Ruby | env-gated stage — no race ✅ | **was EADDRINUSE-only → crash** → FIXED |
| Node | mounted before listen — no race ✅ | **EADDRINUSE-only logged; others silently swallowed** → FIX |

(a) is guaranteed by construction in all four — no source change anywhere.
(b) Ruby was the real outlier (other errors crashed the main server); Node logs
only EADDRINUSE and silently swallows the rest leaving a dangling server.

## Tests (real, no mocks, positive + negative)
- [ ] aux-port: debug-on, aux port forced to fail with a non-EADDRINUSE error
      (main port in 64536..65535 ⇒ aux = main+1000 > 65535 ⇒ Socket::ResolutionError);
      main server still serves /health 200 (RED without the broad rescue).
- [x] serve-debug 4 cases stay green via the generous-deadline poll.

## Bugs
- [x] webserver.rb aux-port rescue caught only Errno::EADDRINUSE (Ruby) — a
      transient getaddrinfo/Socket::ResolutionError, EADDRNOTAVAIL or EACCES on
      the aux port crashed the whole main server during boot.
- [ ] Node aux-port 'error' handler silently swallows non-EADDRINUSE codes.

## Commits
- (log here)

## Status: In Progress
