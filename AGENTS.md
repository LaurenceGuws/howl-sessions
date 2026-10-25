# Howl Sessions Agent Contract

Howl Sessions is the product composition above Howl's terminal primitives.
It owns Server -> Sessions -> Instances orchestration and application hosts.
Howl retains VT, PTY, Instance, Text, Render, and direct local hosts.

## Ownership

- A local Instance works without Server, a network endpoint, or a Session.
- Server and Session own identity, orchestration and attachment, never terminal
  semantics, authoritative geometry, rendering, or platform UI.
- Client packages own bounded transport and cancellation, not server state.
- A host may compose local Instances, remote Sessions, or both. Flutter and Odin
  must not import Server merely to use a local Instance.
- The module that owns an operation owns its foreign interface. Hosts own
  presentation, scheduling, settings and application lifecycle.
- One terminal attachment has one dedicated Instance connection. Slow or
  disconnected observers cannot slow canonical terminal service.
- All retained queues, processes, buffers, borrowed lifetimes and wire messages
  have explicit bounds, errors and cleanup proofs.

## Versions and releases

Each externally consumable module, protocol and host owns an independent
version, dependency contract, test gate and releasable artifact. Private helper
files do not get ceremonial versions. Wire/ABI versions are distinct from
package versions. VERSION and snapshot.json identify a tested combination,
never force a child to move in lockstep.

During extraction, paths into the adjacent howl checkout are a development
bridge only. Do not promote a release while such a dependency remains.

## Engineering and Git

Use the exact tracked Zig from PATH; check .zigversion. Favor Foot-like
directness and TigerBeetle-style correctness: explicit ownership, stable types,
exact failure handling and evidence-backed changes. No speculative managers
or duplicated representations. Start with the checked-in original hosts as
behavior references, not sources to keep in parallel indefinitely.

`main` is accepted integration. Preserve unrelated changes. Do not make
branches or worktrees without Captain's approval. Before committing, run the
affected package tests, root test/check and audit gates, formatting and
`git diff --check`. An audit-tool failure is a blocker, not a green check.
The workspace check runs child compilation/tests plus the one root Git-owned
zig-audit; standalone package audits run only when the package is a Git root.
