# DaemonicCabal.jl — Observations & warts

Collected during the Zig-learning port review. Not a plan, just reminders of tensions in the current POSIX code that could be improved independent of the Windows port.

## Blocking I/O inside the event loop thread

### Stalled-client read wedges the conductor
- **Where**: `conductor/main.zig:333` `handleConnectionFd` → `readExact(socket, &magic_buf)`, called from `handleAccept` inside the kqueue/io_uring loop.
- **Problem**: client sockets from `accept()` are blocking by default. A client that connects but sends nothing (slow, stalled, malicious) blocks the entire event loop — no other clients accepted, no timers fire, no signal pipe read. The 4-byte magic read, the request header read, and the body reads are all blocking.
- **Why it works today**: clients are local (conductor socket is in a per-user runtime dir) and send magic + request immediately after connect. `setRecvTimeout` is applied to *worker* sockets but not client sockets.
- **Fix (minimal)**: `fcntl(client_fd, F_SETFL, O_NONBLOCK)` after `accept`, then handle `EAGAIN` from `readExact` (returns error promptly on stalled client).
- **Fix (proper)**: register `client_fd` with kqueue/io_uring after accept; return to the loop; read request bytes only when the loop reports the fd readable. Per-connection state machine instead of synchronous read. Bigger rewrite but eliminates the exposure class entirely.

### Worker connect-back accept has no timeout
- **Where**: `conductor/worker.zig:326` `setup.server.accept(io)`, called from `spawnImpl` inside the event loop thread (via `handleAccept` → `assignClientToWorker` → `selectWorker` → `addWorkerToPool`).
- **Problem**: blocking `accept` waiting for the Julia worker to connect back to `wsetup.sock`. If the worker crashes between `std.process.spawn` and `runworker`'s connect (bad executable, missing package, instant crash), the accept blocks forever. Worse: we're in a blocking syscall, not in the kqueue loop, so the signal pipe can't save us — SIGTERM's pipe-write happens but nobody reads it.
- **Why it works today**: Julia-startup-then-crash-before-connect is rare and usually fast. Recoverable via `--restart` or external SIGKILL.
- **Fix**: timeout on the setup listener accept. Either a `setRecvTimeout`-style socket option applied *before* the accept, or a kqueue-registered accept with a linked timeout (like the ping read+timer pair). On timeout, reap the spawned child and propagate `error.WorkerStartupFailed`.

## Process lifecycle on conductor hard crash

### Orphaned Julia workers burn RAM until self-termination
- **Where**: `conductor/main.zig:1971` `cleanupRuntimeDir` runs at startup, but only wipes socket/PID files — it does not kill Julia worker processes left running by a previous crashed conductor.
- **Problem**: if the conductor is SIGKILLed (OOM, `kill -9`, power loss) while workers are alive, the workers are separate processes (no `PR_SET_PPR`), so they keep running. They hold warm Julia state (hundreds of MB each), try to ping the dead conductor, fail, and eventually hit their own TTL exit — but that can be hours (`MAX_TTL` default 2h). Meanwhile they consume RAM.
- **Why it works today**: hard crashes are rare; `MAX_TTL` eventually reaps them; users can `pkill -f julia` manually.
- **Fix**: at startup, after `cleanupRuntimeDir`, read `conductor.pid` (before wiping it), check if that PID is still alive and is a `julia-conductor` (not a recycled PID), and if not, walk the worker sockets/PIDs and SIGKILL orphans. Or: workers could watchdog the conductor (ping the conductor socket; on `ECONNREFUSED`, exit immediately). The worker-side watchdog is cleaner — no PID-recycling risk, no startup logic.

## Blanket runtime-dir wipe

### `cleanupRuntimeDir` assumes single-user-single-conductor
- **Where**: `conductor/main.zig:316-329`.
- **Problem**: iterates every entry in `runtime_dir` and deletes files + recursively deletes subdirs. A second conductor instance sharing the runtime dir (different transport, parallel experiment, misconfiguration) would have all its sockets nuked on the second startup.
- **Why it works today**: the single-user-single-conductor assumption holds in practice; runtime dirs are per-user (`/run/user/$UID/...` on Linux, `~/Library/...` on macOS).
- **Fix**: only delete entries the conductor can identify as its own (match `conductor.sock`, `conductor.pid`, `wsetup-*.sock`, `sandbox-*/` patterns). Leaves anything unrecognized alone. Trades a small risk of incomplete cleanup for not clobbering foreign state.

## Windows-port considerations (not warts, but porting notes)

These are divergences, not bugs in the current code. Recorded here so they're not rediscovered later.

- **Sandbox path is Linux-only** (`worker.zig:254-298`): `fork`+`unshare`+bind-mounts+`execve` has no Windows analog. Windows sandboxing = Job Objects + restricted tokens / WSL / containers — a separate implementation, not a port. `--sandbox` should be rejected on Windows (it already is: `main.zig:414` `comptime builtin.os.tag != .linux`).
- **Process groups / `kill(-pgid, sig)`**: `worker.zig:323` already gates `.pgid = null` on Windows. The `kill(pid, SIG.INT)` path in `handleNotification` (`main.zig:371`) needs a Windows equivalent — likely `GenerateConsoleCtrlEvent` (if the worker is in the conductor's console) or a job-object signal / named-pipe interrupt message.
- **`AF_UNIX` vs named pipes**: Windows 10 1803+ has `AF_UNIX` (possible shortcut: keep the socket code, handle Windows-specific bits). Named pipes are the broader-compat option but rewrite the listen/accept layer. Decision point for the port.
- **Event loop**: kqueue/io_uring → IOCP. Readiness model vs completion model — inverted semantics, biggest porting challenge. Zig's `std.Io` (`Io.net.*.listen` in `protocol.zig:275`) is the stdlib's unification attempt; needs evaluation of how far it gets us on Windows.
