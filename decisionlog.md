# Captain's decisions

## A sibling product, not a canary directing Howl core

Recorded 2 November 2026 from Captain's explanation of the earlier decision.

**Decision:** Howl Sessions owns Server and its supporting modules and hosts.
Server is core to this product family; Flutter is a product host, not a
throwaway canary. Howl's terminal primitives remain independently useful.

**Why:** Server/Flutter bring-up had grown beyond its original canary role and
was influencing the important terminal core. The repository split establishes
a separate scope and responsibility, not merely a new directory for the same
coupling. Core/product are ownership commitments, not claims of release maturity.

## Keep the knowledge; build a readable Flutter host

**Original intent:** relocate the existing owners intact, retain the old Flutter
host as a reference, then develop a fresh host beside it.

The old host contained valuable engineering, but accumulated bring-up paths,
compatibility layers and successive ABI experiments inside large, poorly named
owners. Maintaining those historical alternatives in the active build was not
the intended destination.

**Subsequent decision:** after the extraction and Flutter changes had become
intermixed across many commits, Captain accepted a fresh, slower and intentional
design rather than undoing the migration. The current host is that deliberate
replacement. Its greater readability is useful even though it remains incomplete.

Use the original host and Git history as reference material for established
behaviour, edge cases and lessons. Do not rediscover known constraints needlessly,
but do not restore abandoned ABI versions or compatibility layers just to retain
old bring-up code. Historical reference code does not automatically earn a place
in the maintained build/test graph.

Before expanding the host, establish the current owner and interface for the
behaviour being added. Tests establish particular behaviour, not architectural
quality by themselves. Preserve clear names, small owners and one accepted path.
