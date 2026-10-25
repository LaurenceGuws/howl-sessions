# howl CLI

`howl` is the machine-friendly native command surface for Howl. It owns no PTY, VT, Instance, Session, Server, listener, discovery, authentication, or supervision.

Two command families stay deliberately distinct:

- `howl instance ...` performs snapshots/state/input/resize/focus/signals against one exact Instance. Its target is `--server SERVER_ENDPOINT SERVER_ID SESSION_ID INSTANCE_ID`. The client validates the Server incarnation and completes one dedicated attachment at the shared ready response.
- `howl server run LISTEN` hosts one foreground Server runtime and its single control listener.
- `howl server ...` client commands talk to one explicit Server control stream for status/tree inspection and exact Session/Instance lifecycle CRUD.

The Instance target grammar is shared by every interaction command:

```text
TARGET = --server SERVER_ENDPOINT SERVER_ID SESSION_ID INSTANCE_ID

howl instance snapshot TARGET --text
howl instance type TARGET 'hello'
howl instance resize TARGET 40 120
```

`--server` describes only how the client obtains the exact Instance stream. Interaction
semantics remain Instance-owned; no snapshot/input/resize command becomes Server CRUD.

Server orchestration preserves the ownership tree. `server session create` creates only logical Session identity. `server instance create` is the only command that accepts shell/command/cwd/geometry. IDs and revisions are emitted as decimal JSON strings where they may exceed JavaScript's exact integer range.

The Server runtime owns no terminal geometry or presentation layout. `server instance create`
selects the initial canonical geometry for that Instance; later Server terminal resize mutates that same
Instance geometry. Multiple Instances may be shown on one app surface, but panes/splits and
surface composition remain client-side.

Managed target identity includes the expected `SERVER_ID` from Server status/tree
(or the run receipt), before Session and Instance IDs. All three are nonzero decimal
u64 values. A reused endpoint with a different Server incarnation fails closed as
stale; explicitly browse/select the new Server instead of silently reconnecting to
its reused Session/Instance numbers. This is target identity, not authentication.
