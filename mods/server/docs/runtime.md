# Server runtime

The Server family's `server_runtime` entry point serves the existing
`howl server run` CLI. It composes the [listener-free model/service](../README.md)
and presentation-free Instance. It owns listener, scheduling and shutdown policy.
Remote clients select the [shared wire](protocol.md) and client module instead.

## Runtime

`server_runtime` owns one listener, one Server model, one control service, and the
bounded scheduling loop for every Instance interaction service in that process.
The listener accepts only Server control connections. Exact Instance attach transfers
the accepted stream directly into the Server-owned terminal service beside that Instance; no per-Instance
listener or byte proxy exists.

The scheduler separates readiness from service work. Running Instances with no clients,
pending writes or terminal deadlines contribute only their PTY fd to one aggregate poll.
Server control sockets contribute the exact readiness mask requested by `server_service`:
ordinary clients wait for input, queued responses wait for output, and parked tree
observers wait only for disconnect while tree-revision changes wake them explicitly.
The Server listener, those control sockets and dormant PTYs therefore share one aggregate
readiness wait. PTY output/EOF, control input/output and new Server connections wake the
runtime immediately. Leader exit is also reconciled over the bounded live set at the
one-second housekeeping deadline: a quiet descendant can retain the PTY after its
leader exits, so leader exit is not itself a PTY-readiness guarantee. Server terminal-client
work and Instance timer/write work use the bounded rotating direct-service lane. Retained
exited Instances remain attachable but disappear from all scheduler work once their PTY,
clients, terminal timers, consequences and publication work are quiescent; a later exact
attach makes that Instance serviceable again. The aggregate dormant wait has only a
bounded housekeeping timeout; it is not an input/output latency bound.

This is intentionally replaceable runtime scheduling policy, not Session or Instance semantics.

TCP accept policy is part of the runtime's interactive carriage contract. Every accepted
TCP stream has `TCP_NODELAY` enabled before it enters `server_service`; option failure
retires that accepted fd instead of silently degrading request/response latency. Exact
Instance attach transfers the same configured fd onward to its dedicated terminal service. Unix listeners do not
receive TCP policy. Any deployment relay/proxy in front of the Server creates additional
TCP legs and must configure NODELAY on those owned sockets independently; endpoint
configuration cannot reach through a proxy and tune its sockets.

The runtime owns no terminal geometry. Each Instance keeps one canonical rows/columns
and cell-pixel lattice in its VT/PTy lifetime. A graphical client may compose multiple
Instances onto one surface and choose their individual geometries, but that pane/layout
composition remains entirely client-side.

## Listener ownership and shutdown

Unix listener startup refuses any existing pathname, including stale sockets. Removing
an explicitly identified stale endpoint is the caller's responsibility. The endpoint's
containing directory must be owner-controlled. Cleanup compares socket device/inode
identity before unlinking, so an older listener cannot remove a replacement endpoint;
this is not protection against hostile concurrent renames in a shared directory.

The foreground `howl server run` host handles SIGINT/SIGTERM by publishing only a
termination flag from the signal handler. The bounded runtime loop then returns through
ordinary reverse teardown, including the existing PTY process-group stop/escalation.
The aggregate wait yields on signal interruption; repeated termination signals do not
restart the idle timeout or postpone shutdown until signals stop.
SIGKILL and descendants that deliberately leave the owned group are not covered by
this ordinary shutdown contract. Client response/materialization failures retire that
client; canonical PTY/VT owner failures still propagate.
