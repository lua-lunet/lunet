# Test Agent Notes

## Testing Rules (STRICT)

1. **MANDATORY TIMEOUTS:** All test runs MUST use a timeout wrapper to prevent hanging the agent. Use `timeout_ms` in `run_shell_command` (suggested: 5000ms for unit tests, 10000ms for stress/integration).
2. **UDP Backgrounding:** Always run server-like tests in the background (e.g., `command &`).
3. **Cleanup:** Always kill background processes when done. Use `echo $! > server.pid` to track PIDs.
4. **Port Cleanup:** If a test fails with "address already in use", check for leaked processes (`lsof -i :<port>`).

### Example Test Pattern
```bash
./build/lunet test/udp_echo.lua & 
SERVER_PID=$!
sleep 1
./build/lunet test/udp_echo_client.lua
kill $SERVER_PID
```

## Inventory of Test Tools

| Tool | Purpose | Usage |
|------|---------|-------|
| `test/udp_echo.lua` | Echo server on port 20001 | `./build/lunet test/udp_echo.lua` |
| `test/udp_echo_client.lua` | Sends ping to echo server | `./build/lunet test/udp_echo_client.lua` |
| `test/udp_trace_test.lua` | Verifies BIND/TX/CLOSE trace counts | `./build/lunet test/udp_trace_test.lua` |
| `test/udp_queue_trace.lua` | Verifies tracing of queued packets | `./build/lunet test/udp_queue_trace.lua` |
| `test/udp_main_thread.lua` | Verifies coroutine enforcement | `./build/lunet test/udp_main_thread.lua` |
| `test/udp_sink.lua` | Logs packets to `.tmp/udp_sink.log` | `./build/lunet test/udp_sink.lua` |
| `test/stress_test.lua` | Concurrent async op stress test | `./build/lunet test/stress_test.lua` |
| `test/sdk_api.c` | C SDK lifecycle test (one-runtime contract, negative matrix, exit-code plumbing) | `xmake build sdk-api-test && timeout 10 $(find build -name sdk-api-test -type f \| head -1)` — **run from the repo root** (uses the relative path below) |
| `test/sdk_api_script.lua` | Helper for sdk_api.c; sets `__lunet_exit_code = 23` | invoked by the sdk-api-test binary |
| `test/smoke_sqlite3_tx.lua` | `lunet.sqlite3_tx` transaction wrapper: commit, abort-by-nil, raise, statement error, guards (#119) | `xmake build lunet-sqlite3 && xmake build-release` then `$(find build -path '*/release/lunet-run' -type f \| head -1) test/smoke_sqlite3_tx.lua` |

## Tracing Verification

Always build with `xmake build-debug` to enable `LUNET_TRACE`. 
Inspect `stderr` for `[UDP_TRACE]` and `[TRACE]` prefixes.

A balanced run should show:
`All coroutine references properly balanced.`
at the end of the trace summary.
