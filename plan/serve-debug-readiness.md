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

## TRUE ROOT CAUSE (deterministically reproduced + mutation-proven) — PARENT-ENV INHERITANCE
The child env in `dev_status` is `ENV.to_h.reject { TINA4_* }.merge(...)` passed to
`Process.spawn(env, ...)` WITHOUT `unsetenv_others: true`. `Process.spawn` MERGES `env`
onto the PARENT environment; `reject` only OMITS keys, and omission means INHERIT, not
delete. So the child inherited the rspec parent's TINA4_ vars: `spec_helper.rb:18` pins
`TINA4_LOG_LEVEL=NONE`, and whenever a prior example (RSpec random order) left
`TINA4_DEBUG=false` in the parent, the debug-ON child inherited `TINA4_DEBUG=false`. The
temp `.env`'s `TINA4_DEBUG=true` could not win because env load is first-wins
(`ENV[k] ||= v`). The child booted **Debug OFF** → `/__dev` settled 404.

Reproduced deterministically: `TINA4_DEBUG=false bundle exec rspec spec/cli_serve_debug_env_spec.rb`
fails the "debug true" case WITHOUT the fix and passes WITH it. A standalone repro boots the
child `Debug: OFF (Log level: NONE)` (the exact CI-failure banner) without `unsetenv_others`
and `Debug: ON (Log level: ALL)` with it. **FIX: `unsetenv_others: true` on the spawn** — the
child gets exactly the intended env, TINA4_DEBUG genuinely unset, so the `.env` value applies.

Defence-in-depth also kept (a CI failure's log also showed a genuine "port in use", so port
contention is real): `wait_until_serving!` checks child-exit before trusting a 200 and takes an
optional `require_log` identity guard (the child's own `Server: …:<thisport>` banner), so a
foreign server on a reused port is never mistaken for ours; boot retries on a fresh port.

## Earlier (secondary) finding from the CI serve.log — PORT IDENTITY
The flake REPRODUCED on CI under load (2/6 reruns) as a genuine `dev_status == 404`
for the debug-on case. The instrumented failure dumped the child's own serve.log:
```
{:status=>404, :health=>[200, "...uptime:1.19..."], :reprobe=>[404,404,404,404],
 :log=>"Port 39431 is in use and takeover is disabled ... \n Server: http://127.0.0.1:39431 \n Debug: OFF (Log level: NONE)"}
```
So `free_port` handed out an ephemeral port that, under load, a DIFFERENT debug-OFF
server already held (banner `Debug: OFF (Log level: NONE)` — not the config this spec
passes). The debug-on child could not own the port ("is in use and takeover is
disabled"), yet `wait_until_serving!` accepted `/health`=200 from that FOREIGN server,
and the `/__dev` probe then hit the wrong, debug-off server → settled 404. A 200 on the
port proved only that SOMETHING listened, not that it was OUR child. The readiness
theory (#84/#91) and my first harness fix both missed this.

FIX (harness, correct): `wait_until_serving!` now (a) checks child-exit BEFORE accepting
a 200, and (b) takes an optional `require_log` identity guard; `dev_status` requires the
child's OWN `Server: http://…:<thisport>` banner (printed only after the child actually
bound THIS port) before trusting a 200. A contended port therefore fails the boot and
retries on a FRESH port instead of silently probing a foreign server. boot_attempts 3→5.

## Earlier note — the traced "/__dev mounts after /health" race does not exist in Ruby
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
