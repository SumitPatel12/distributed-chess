## What do they simulate?
They stub out whole of the:
- *Clock*: The thing that primirarily drives the time dilation.
- *Network*: Packet re-roders, loss, partitioning, etc.
- *Disk Operations*: We'll have to see why this is necessary, they do try to induce disk faults, but, that's not something I'd need for my implementation

## What kind of faults do they inject? 
Quite Duplicate of the first one now that I see, but I'm gonna keep it.
- Drop or re-roder packets
- Partition the network
- Corrupt Wrties (Likely something I'll not implement for my thing. We still gotta study it though)

In case a sim run fails, they output the *seed* and *commit hash* for replayability.

## What's in their code that enables the simulation to work bettter?
- Asserts for invariants (This doesn't mean just scatter asserts left and right, they follow the NASA's rule of 10).
- Single threaded execution
- Message Bus (This I feel like is the central thing that ties in the systems working)
- Checkers: These scour the simulation space applying sanity checks, and invariants that should hold over the whole state machine. Likely things that are hard to run as asserts.
  - An exapmle of this that they state is that their storage checker checks the logs of the replicas that have caught up, they should be byte-by-byte identical. Fascinating stuff.

## Implementation
The whole of their simulation loop is drived by the `vopr.zig` which stubs in a lot of the files that would have otherwise caused non-determinism. And they've got a ton of configuration around what options drive the simulation environment.

### Packet Simulator
Has ton of options we're not gonna note all of them, a few noteworthy ones are:
- packet_loss_probability
- packet_replay_probability
- *parition_mode*: See below for a bit more detail
- partition_symmetry
- *partition_probability*: Proability that the network will partition after a tick.
- *unpartition_probability*: Same but for unpartitioning
- *path_maximum_capacity*: Maximum number of packets after which the communication line is congested and all subsequent packets drop.

**Partition Mode:** Drives whether to partition the network or not. Partitions are of two types *assymetric* and *symmetric*, the former meaning there is not communication possible bettween the partitions, the latter being one way communiation is possible. It's got 4 options:
1. *none*
2. *uniform_size*: Picks some size from 1 to n (n being number of nodes in the system), and runs with it.
3. *uniform_partition*: Split the nodes in two equal parts, nodes are part of one or the other partition.
4. *isolate_single*: Isolates a single node from the the rest of them.

So What makes sense for me for the barebones implementations:
- packet_loss_prob
- packet_replay_prob
- path_maximum_capacity 
That's pretty much it partitions and stuff while good would be too difficult for the first pass. We keep things simple for the first one.


## References
- [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md)
- And the whole of their simulation code really.
