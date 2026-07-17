# Win32 API map for the DaemonicCabal.jl Windows port

A POSIX-to-Windows reference, organized by the categories covered in `LESSONS.md` L1-L8. Use alongside `LESSONS.md` (OS-internals lessons) and `NOTES.md` (warts observed in the current POSIX code).

## Handles — the defining difference

POSIX has the unified fd namespace (small integers, 0/1/2 are stdio, everything else is just "a number"). Windows has **HANDLE** — an opaque pointer-sized value, *not* a small integer, and *not* a unified namespace:

| POSIX | Windows |
|---|---|
| `int fd` (0..N, small integers) | `HANDLE` (opaque pointer-sized) |
| `close(fd)` works on files, pipes, sockets | `CloseHandle(h)` works on files, pipes, processes, events, timers… **but NOT sockets** (`closesocket`) |
| `open()` returns fd | `CreateFileW()` returns HANDLE |
| `socket()` returns fd | `WSASocket()` returns `SOCKET` (a HANDLE-equivalent but separate type) |

Different handle types have different creation functions and different cleanup. The "everything is a file" Unix philosophy does not hold. This is the root of L3's `socketWrite`/`socketRead`/`close` routing through the `shared` layer.

## Processes and threads

| POSIX | Windows | Notes |
|---|---|---|
| `fork()` + `execve()` | `CreateProcessW()` | No fork. One call: new process, fresh address space, no inherited fd table (only explicitly-inheritable handles via `STARTUPINFOW`/`STARTUPINFOEXW`). No "window between fork and exec." |
| `waitpid(pid, ...)` | `WaitForSingleObject(handle, ...)` / `WaitForMultipleObjects` | Wait on the process *handle*, not the PID. `GetExitCodeProcess` for the status. |
| `kill(pid, SIGTERM)` | `TerminateProcess(handle, exitCode)` | Like SIGKILL — no graceful signal. No SIGTERM equivalent by default. |
| `kill(pid, SIGINT)` | `GenerateConsoleCtrlEvent(CTRL_C_EVENT, pid_group)` | Only works for processes attached to a console. Or: named-pipe message, Event object. |
| `getpid()` | `GetCurrentProcessId()` | |
| `getppid()` | N/A directly | Windows doesn't track parent PIDs the way Unix does (no PPID in the process record). There are hacks (NtQueryInformationProcess with ProcessBasicInformation). |
| `setpgid` / process groups | **Job Objects** | A Job Object is a kernel container that groups processes; `TerminateJobObject` kills them all. `GenerateConsoleCtrlEvent` targets a console process group — a different concept. |
| `posix_spawn` | `CreateProcessW` | The closest analog. |
| `PR_SET_PPR` (die with parent) | Job objects with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` | Close the job handle → all processes in it die. |

The `worker.zig:323` `.pgid = 0` (new process group) becomes: either a Job Object per worker (so `TerminateJobObject` can kill worker+children), or nothing (let the conductor manage kills explicitly). The orphaned-workers problem from `NOTES.md` is actually *easier* on Windows if you put every worker in a Job Object with `KILL_ON_JOB_CLOSE` — the conductor crashes → job handle closes → workers die automatically. A POSIX `PR_SET_PPR` equivalent that actually works.

## Sockets (Winsock, `ws2_32.dll`)

Winsock was originally a separate winsock.dll, then winsock2 (ws2_32). The API is *deliberately POSIX-like* — `socket`, `connect`, `bind`, `listen`, `accept`, `send`, `recv`, `setsockopt`, `getsockname` — with these differences:

| POSIX | Windows | Notes |
|---|---|---|
| `int fd` for socket | `SOCKET` (a HANDLE, unsigned) | `INVALID_SOCKET` (-1 cast) is the error value, not -1. |
| `read(fd, ...)` / `write(fd, ...)` on socket | `recv(s, ...)` / `send(s, ...)` | `read`/`write` do *not* work on sockets on Windows. |
| `close(fd)` | `closesocket(s)` | `CloseHandle` does *not* work on sockets. |
| No init needed | `WSAStartup()` first, `WSACleanup()` last | Must be called once per process before any socket call. `std.Io`'s Windows backend handles this; raw code must do it. |
| `errno` | `WSAGetLastError()` | Different error codes (`WSAECONNREFUSED` vs `ECONNREFUSED`). |
| `fcntl(fd, F_SETFL, O_NONBLOCK)` | `ioctlsocket(s, FIONBIO, &mode)` | Non-blocking mode. |
| `AF_UNIX` (filesystem path) | `AF_UNIX` (Win10 1803+) **or** named pipes | Decision point (L6). |

Named pipes (`CreateNamedPipeW` + `ConnectNamedPipe`, client `CreateFileW`) are the classic Windows local IPC. The listen/accept model *doesn't apply* — `CreateNamedPipeW` creates one instance that accepts one connection; you call it again for the next. Pipes are kernel objects (no filesystem inode, no stale-file cleanup — a Windows win).

## I/O multiplexing (the event loop)

| POSIX | Windows | Notes |
|---|---|---|
| `kqueue` (BSD/macOS) | **IOCP** (I/O Completion Ports) | Completion model, not readiness. |
| `epoll` (Linux) | IOCP | Same. |
| `io_uring` (Linux) | IOCP | Closest analog — both completion. |
| `select` / `poll` | `select` (Winsock) / `WSAPoll` | Exist but don't scale; IOCP is the real answer. |
| `signalfd` / self-pipe | `SetConsoleCtrlHandler` + Event object | The handler runs in its own thread; signal an Event; loop waits on it with `WaitForMultipleObjects`. No self-pipe needed. |
| `timerfd` / kqueue `EVFILT.TIMER` | **Waitable Timer** (`CreateWaitableTimerW`, `SetWaitableTimer`) | Can be waited on with `WaitForMultipleObjects` alongside IOCP. Or use `CreateTimerQueueTimer`. |

IOCP (`CreateIoCompletionPort`, `GetQueuedCompletionStatus`, `PostQueuedCompletionStatus`):
- You **associate** a handle with a completion port once (`CreateIoCompletionPort(handle, existing_port, key, 0)`).
- You issue **overlapped** I/O: `ReadFile(handle, buf, len, &bytes, &OVERLAPPED)` returns immediately; completion is posted to the port.
- `GetQueuedCompletionStatus(port, &bytes, &key, &OVERLAPPED**, timeout)` blocks until a completion arrives. The `key` is your per-handle cookie (like kqueue's `udata`). The `OVERLAPPED*` identifies the specific operation.
- One port can multiplex many handles. Threads can wait on the same port (thread pool dispatch).

The model is: **"I'm starting a read; tell me when it's done"** — opposite of kqueue's "tell me when it's ready, I'll read it myself." The io_uring loop in `client/eloop/linux.zig` is the closest structural analog: it submits reads up front and processes completions. A Windows IOCP loop would look similar but use `ReadFile`/`WSARecv` with `OVERLAPPED` instead of `ring.read`, and `GetQueuedCompletionStatus` instead of `submit_and_wait`.

A subtlety: on Windows, to wait on *both* IOCP completions *and* console control events / waitable timers in one call, you'd use `WaitForMultipleObjectsEx` with `GetQueuedCompletionStatusEx` (which can return multiple completions + is alertable), or you'd post a completion for the timer/console event via `PostQueuedCompletionStatus` from the timer callback / console handler thread. The latter is the self-pipe-trick equivalent — convert everything into completions. This unifies the event loop into a single `GetQueuedCompletionStatus` call.

## Files and directories

| POSIX | Windows | Notes |
|---|---|---|
| `open()` / `creat()` | `CreateFileW(path, access, share, ..., creation, ...)` | One function for open/create/open-if-exist. `GetLastError()` distinguishes outcomes. |
| `read()` / `write()` | `ReadFile` / `WriteFile` | Sync (overlap=NULL) or overlapped (async). |
| `close(fd)` | `CloseHandle(handle)` | |
| `unlink()` | `DeleteFileW()` | |
| `mkdir()` | `CreateDirectoryW()` | |
| `rmdir()` | `RemoveDirectoryW()` | |
| `opendir`/`readdir` | `FindFirstFileW`/`FindNextFileW` | Pattern-based (`"C:\\dir\\*"`), returns `WIN32_FIND_DATAW`. |
| `stat()` | `GetFileAttributesExW()` | |
| `rename()` | `MoveFileExW()` | |
| `symlink()` | `CreateSymbolicLinkW()` | Requires privilege or developer mode on older Windows. |
| `STDIN_FILENO`/`STDOUT_FILENO`/`STDERR_FILENO` (0/1/2) | `GetStdHandle(STD_INPUT_HANDLE)` etc. | Returns a HANDLE, not a fixed integer. |

Paths: Windows uses drive letters + backslashes (`C:\Users\...`), and supports UNC paths (`\\server\share\...`) and `\\?\` long-path prefix. There's no single root `/`. The `defaultRuntimeDir` port would use `%LOCALAPPDATA%\julia-daemon` (via `SHGetKnownFolderPath(FOLDERID_LocalAppData)`) — the Windows equivalent of `XDG_RUNTIME_DIR`-ish (persisted, per-user, but NOT ephemeral like `/run/user/$UID` — Windows has no standard per-user tmpfs).

## Terminal

| POSIX | Windows | Notes |
|---|---|---|
| `tcgetattr`/`tcsetattr` + `termios` | `GetConsoleMode`/`SetConsoleMode` (on a console handle) | Totally different struct (`ENABLE_ECHO_INPUT`, `ENABLE_LINE_INPUT`, `ENABLE_VIRTUAL_TERMINAL_INPUT`…). Windows 10+ supports VT sequences (`ENABLE_VIRTUAL_TERMINAL_PROCESSING`) which makes output closer to ANSI terminals. |
| `ioctl(TIOCGWINSZ)` | `GetConsoleScreenBufferInfo` → `.dwSize` / `.srWindow` | |
| `isatty()` | `GetFileType(handle) == FILE_TYPE_CHAR` | Or `GetConsoleMode` succeeds. |

The raw-mode + `\x03` interrupt routing in the client (`platform/posix.zig:87-98`, L7) maps to `SetConsoleMode` disabling `ENABLE_LINE_INPUT` + `ENABLE_ECHO_INPUT`, and a `SetConsoleCtrlHandler` for `CTRL_C_EVENT` that writes `\x03` to the worker's stdin pipe. Actually *simpler* on Windows because the console control handler runs in its own thread (no async-signal-safety gymnastics).

## Memory info

| POSIX | Windows | Notes |
|---|---|---|
| Linux PSI (`/proc/pressure`) | None equivalent | TTL-only on Windows. |
| Linux `/proc/meminfo` `MemAvailable` | `GlobalMemoryStatusEx` → `MEMORYSTATUSEX.ullAvailPhys` | |
| macOS `host_statistics64` | `GlobalMemoryStatusEx` | Same. |
| macOS `phys_footprint` via `proc_pid_rusage` | `GetProcessMemoryInfo` (psapi) → `PROCESS_MEMORY_COUNTERS_EX.WorkingSetSize` | RSS-equivalent. No USS-equivalent without walking the virtual address space (`VirtualQueryEx` loop). |

The `pressure.zig` module would be inert on Windows (TTL-only), and `getProcessStats` would use `GetProcessMemoryInfo`.

## Signals — there are none

| POSIX | Windows | Notes |
|---|---|---|
| `sigaction` + handler (runs on interrupted thread) | `SetConsoleCtrlHandler` (runs in **separate thread**) | Only for console events (Ctrl-C, Ctrl-Break, close, logoff, shutdown). Not a general mechanism. |
| `kill(pid, signum)` | `TerminateProcess` (always "kill") or `GenerateConsoleCtrlEvent` (only console-attached) | No general "send signal N to pid." |
| Self-pipe trick | Not needed — handler runs in its own thread, can use normal sync | Just signal an `Event` and have the loop wait on it, or `PostQueuedCompletionStatus` to inject a completion. |
| `SIGCHLD` (child died) | `RegisterWaitForSingleObject` on the process handle, or poll `GetExitCodeProcess` | No async notification; you register a wait callback or poll. |
| `SIGHUP` (terminal closed) | `CTRL_CLOSE_EVENT` / `CTRL_LOGOFF_EVENT` in `SetConsoleCtrlHandler` | |

## The W/A Unicode split

Most Win32 functions have two variants: `CreateFileA` (ANSI, char*) and `CreateFileW` (wide, UTF-16 `WCHAR*`). The W variant is the real implementation; the A variant wraps it (converts via the system code page, which loses information for non-system-locale characters). **Always use W.** In Zig, `std.os.windows` provides bindings that take `[*:0]const u8` (UTF-8) and convert internally to UTF-16 for you — so you rarely call `CreateFileW` directly; you call `std.os.windows.kernel32.CreateFileW` with a UTF-16 string you built via `std.unicode.utf8ToUtf16Le` or similar. The `std.Io` Windows backend handles all of this.
