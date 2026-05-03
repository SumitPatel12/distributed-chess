# Paxos API

Status: draft.

This document defines an API for basic, single-instance Paxos. The design should be small enough to understand, deterministic enough to test in simulation, and instrumented enough to drive a frontend animation of the proposal flow.

The design below follows the usual Paxos split:

- each process can act as proposer, acceptor, and learner
- a value is chosen once a quorum of acceptors accepts the same proposal
- the protocol core is event-driven so it can run under deterministic simulation testing
- durable protocol state and animation trace logs are separate

## Scope

### Goals

- Implement single-instance Paxos for one chosen value.
- Support multiple nodes, where each node can run all Paxos roles.
- Make proposal numbers globally unique and totally ordered.
- Make the protocol testable with a deterministic runtime.
- Preserve safety across node crash/restart by persisting the required single-instance state.
- Record enough trace data to animate prepare, promise, accept, accepted, and chosen events.

### Non-goals

- Multi-Paxos.
- Replicated state machine logs.
- Dynamic membership.
- Network discovery.
- Byzantine behavior.
- Blocking sleeps or direct system-time reads inside the Paxos core.

Cluster membership is supplied through `ClusterConfig`. Network discovery is outside this API.

## Model

Paxos assumes an asynchronous, non-Byzantine system:

- Nodes may stop and restart.
- Messages may be lost, duplicated, delayed, or reordered.
- Messages are not corrupted.
- Safety must hold regardless of timing.
- Liveness may require a distinguished proposer, backoff, randomness, or real time. Those are progress tools, not safety requirements.

## Core Types

Pseudo-Zig:

Names such as `Map`, `Set`, and `EffectList` are abstract container names.

Function and method names in the snippets below are written in `camelCase` for readability against the original Paxos literature. The actual Zig implementation uses `snake_case` for all free functions and methods (e.g. `quorum_size`, `on_input`, `handle_prepare`, `is_less_than`, `quorum_reached`).

```zig
// Distinct integer types via Zig's non-exhaustive enum newtype pattern.
// Zero runtime cost (same memory layout as the underlying integer), but the
// compiler refuses to mix them. Convert with @intFromEnum / @enumFromInt.
const NodeId = enum(u32) { _ };
const TimerId = enum(u64) { _ };

const ProposalNumber = struct {
    epoch: u64,
    proposer_id: NodeId,
};

const Value = struct { bytes: []const u8 }; // Opaque application value.

const AcceptedProposal = struct {
    proposal_number: ProposalNumber,
    value: Value,
};

const ClusterConfig = struct {
    self: NodeId,
    // Cluster contains exactly `size` nodes whose `NodeId`s are 0..size-1.
    // The mapping from NodeId to physical address (hostname, IP, etc.) lives
    // outside this API in deployment config. The protocol core only deals in
    // positions.
    size: u32,

    pub fn quorumSize(self: ClusterConfig) usize {
        return (self.size / 2) + 1;
    }
};
```

`ProposalNumber` is ordered lexicographically:

1. higher `epoch` wins
2. if epochs are equal, higher `proposer_id` wins

This gives each proposer a disjoint proposal-number space while keeping proposal numbers easy to compare.

## Runtime Boundary

The protocol core should not block on sockets, sleep, read system time, or call randomness directly. Instead, it handles deterministic inputs and returns effects for the runtime or simulator to execute.

```zig
const Input = union(enum) {
    client_propose: Value,
    packet_delivered: Packet,
    timer_fired: TimerId,
    recovery_complete,
};

const Effect = union(enum) {
    send: Packet,
    start_timer: TimerStart,
    cancel_timer: TimerId,
    persist: DurableLogEntry,
    emit_trace: TraceEvent,
    chosen: Chosen,
    terminate,
};

fn onInput(node: *PaxosNode, input: Input, out: *EffectList) void;
```

Host runtimes drive this event loop until they observe `terminate` — emitted once every reachable peer has been informed of the chosen value, or the dissemination retry budget is exhausted. `chosen` fires earlier (the moment this node first knows the value) and is informational; `terminate` is the shutdown signal. See the Termination section. Deterministic simulation drives the same core with simulated time, seeded randomness, and a simulated network.

## Messages

Every network message is carried in a `Packet` — the transport unit the runtime/simulator routes between nodes. The `Packet` carries routing (`from`, `to`), observability (`id`, `correlation_id`), and the protocol payload (`message`). The simulator drops/duplicates/delays/reorders `Packet`s; the protocol core sees `Packet`s only via `Input.packet_delivered`.

```zig
const PacketId = enum(u64) { _ };
const CorrelationId = enum(u64) { _ };

const Packet = struct {
    id: PacketId,
    correlation_id: CorrelationId,
    from: NodeId,
    to: NodeId,
    message: Message,
};

const Message = union(enum) {
    prepare_request: PrepareRequest,
    promise: Promise,
    prepare_rejected: PrepareRejected,

    accept_request: AcceptRequest,
    accepted: Accepted,
    accept_rejected: AcceptRejected,

    chosen: Chosen,
};

const PrepareRequest = struct {
    proposal_number: ProposalNumber,
};

const Promise = struct {
    proposal_number: ProposalNumber,
    // Highest-numbered proposal accepted by this acceptor with number less than proposal_number, if any.
    highest_accepted: ?AcceptedProposal,
};

const PrepareRejected = struct {
    proposal_number: ProposalNumber,
    highest_promised: ProposalNumber,
};

const AcceptRequest = struct {
    proposal_number: ProposalNumber,
    value: Value,
};

const Accepted = struct {
    proposal_number: ProposalNumber,
    value: Value,
};

const AcceptRejected = struct {
    proposal_number: ProposalNumber,
    highest_promised: ProposalNumber,
};

const Chosen = struct {
    proposal_number: ProposalNumber,
    value: Value,
};

const PrepareResponse = union(enum) {
    promise: Promise,
    prepare_rejected: PrepareRejected,
};

const AcceptResponse = union(enum) {
    accepted: Accepted,
    accept_rejected: AcceptRejected,
};
```

A successful prepare response is a promise for the requested proposal number. It also carries the highest-numbered proposal accepted by that acceptor with number less than the requested proposal number, if any.

## Acceptor

Acceptor state is the smallest piece that must be persisted for crash/restart safety.

```zig
const AcceptorState = struct {
    highest_promised: ?ProposalNumber,
    accepted: ?AcceptedProposal,

    fn highestAcceptedLessThan(self: AcceptorState, n: ProposalNumber) ?AcceptedProposal {
        if (self.accepted) |proposal| {
            if (proposal.proposal_number < n) return proposal;
        }
        return null;
    }
};
```

### Prepare Handler

```zig
fn onPrepare(state: *AcceptorState, request: PrepareRequest) PrepareResponse {
    const n = request.proposal_number;

    if (state.highest_promised == null or n > state.highest_promised.?) {
        state.highest_promised = n;
        // Persist highest_promised before sending Promise.
        return .{ .promise = .{
            .proposal_number = n,
            .highest_accepted = state.highestAcceptedLessThan(n),
        }};
    }

    if (n == state.highest_promised.?) {
        // Duplicate prepare for the same globally unique proposal number.
        return .{ .promise = .{
            .proposal_number = n,
            .highest_accepted = state.highestAcceptedLessThan(n),
        }};
    }

    return .{ .prepare_rejected = .{
        .proposal_number = n,
        .highest_promised = state.highest_promised.?,
    }};
}
```

### Accept Handler

```zig
fn onAccept(state: *AcceptorState, request: AcceptRequest) AcceptResponse {
    const n = request.proposal_number;

    if (state.highest_promised == null or n >= state.highest_promised.?) {
        state.highest_promised = n;
        state.accepted = .{
            .proposal_number = n,
            .value = request.value,
        };
        // Persist highest_promised and accepted before sending Accepted.
        return .{ .accepted = .{
            .proposal_number = n,
            .value = request.value,
        }};
    }

    return .{ .accept_rejected = .{
        .proposal_number = n,
        .highest_promised = state.highest_promised.?,
    }};
}
```

Acceptor handlers should be idempotent. Duplicate messages must not corrupt state or count as multiple quorum votes at the proposer/learner.

## Proposer

```zig
const ProposerState = struct {
    next_epoch: u64,
    active: ?ActiveProposal,
};

// Bound to a single proposal attempt. Inserts whose proposal_number does not
// match `bound_to` are rejected at the boundary, so a delayed message from an
// abandoned attempt cannot bleed into the current attempt's quorum count.
//
// `NodeId` is itself the bitset position (NodeIds are 0..cluster.size-1), so
// recording a vote is a single bit-set with no map lookup. The bitset is
// fixed-size: no allocation, deterministic iteration, popcount for size,
// idempotent under duplicate deliveries.
const PromiseQuorum = struct {
    bound_to: ProposalNumber,
    received: BitSet,                     // bit i set => NodeId i has voted
    highest_seen: ?AcceptedProposal,      // running max of highest_accepted across voters

    fn record(self: *PromiseQuorum, cluster: ClusterConfig, from: NodeId, msg: Promise) bool {
        if (!ProposalNumber.eql(msg.proposal_number, self.bound_to)) return false;
        const idx = @intFromEnum(from);
        if (idx >= cluster.size) return false;            // out-of-cluster sender
        if (self.received.isSet(idx)) return false;       // dedupe by sender
        self.received.set(idx);
        if (msg.highest_accepted) |hp| {
            if (self.highest_seen == null or hp.proposal_number > self.highest_seen.?.proposal_number) {
                self.highest_seen = hp;
            }
        }
        return true;
    }

    fn quorumReached(self: PromiseQuorum, cluster: ClusterConfig) bool {
        return self.received.count() >= cluster.quorumSize();
    }
};

// Owned by the learner, one per proposal_number observed. The proposer does NOT
// run a parallel accept-count; it transitions Phase.accepting -> Phase.chosen by
// observing its local learner's `chosen` state for its own proposal_number.
//
// Under the non-Byzantine, no-corruption model and unique proposal numbers, all
// Accepted messages for a given proposal_number carry the same value, so we
// record `value` once on creation.
const AcceptQuorum = struct {
    bound_to: ProposalNumber,
    value: Value,
    received: BitSet,

    fn record(self: *AcceptQuorum, cluster: ClusterConfig, from: NodeId, msg: Accepted) bool {
        if (!ProposalNumber.eql(msg.proposal_number, self.bound_to)) return false;
        const idx = @intFromEnum(from);
        if (idx >= cluster.size) return false;
        if (self.received.isSet(idx)) return false;
        self.received.set(idx);
        return true;
    }

    fn quorumReached(self: AcceptQuorum, cluster: ClusterConfig) bool {
        return self.received.count() >= cluster.quorumSize();
    }
};

const ActiveProposal = struct {
    proposal_number: ProposalNumber,
    original_value: Value,
    chosen_accept_value: ?Value,
    phase: Phase,
    promises: PromiseQuorum,
    highest_rejection: ?ProposalNumber,

    // At most one of these is non-null at any time — the timer for the current
    // phase. The dispatcher cancels the live one before phase transitions and
    // matches `timer_fired(id)` inputs against these slots to route the event.
    prepare_timer: ?TimerId,
    accept_timer: ?TimerId,
    retry_backoff_timer: ?TimerId,
};

const Phase = enum {
    idle,
    preparing,
    accepting,
    backing_off,
    chosen,
};
```

### Proposal Flow

1. On `client_propose(value)`, choose a fresh proposal number `n` and create an `ActiveProposal` whose `promises.bound_to = n`.
2. Send `prepare_request(n)` to all acceptors, including self.
3. Start a deterministic prepare timer.
4. Route every incoming `Promise` through `promises.record(cluster, from, msg)`. Records returning `false` are stale (mismatched `bound_to` or duplicate sender) and are dropped — they MUST NOT contribute to quorum or to value selection.
5. When `promises.quorumReached(cluster)`:
   - if `promises.highest_seen` is set, use that proposal's value as `chosen_accept_value`
   - otherwise use `original_value`
6. Send `accept_request(n, chosen_accept_value)` to the promise quorum. Sending to additional acceptors is allowed.
7. Start a deterministic accept timer.
8. The local learner counts `Accepted` votes (its own `AcceptQuorum` for `n`) and emits `Effect.chosen` when it crosses quorum. The proposer transitions to `Phase.chosen` by observing `LearnerState.chosen.proposal_number == n` in the same `onInput` cycle. The proposer does not maintain a parallel accept-quorum count — there is exactly one emitter of `Effect.chosen`.
9. On timeout, or once quorum is impossible (more than half the cluster has rejected), abandon the active proposal, transition to `Phase.backing_off`, and start a `retry_backoff` timer with a randomized duration. The randomization breaks dueling-proposer symmetry: two proposers timing out together pick different waits, so one wins the next race instead of both bumping each other forever.
10. When `retry_backoff` fires, begin a fresh prepare with a proposal number higher than `highest_rejection` and higher than any number this proposer has used before.

The proposer must never reuse a proposal number after abandoning it.

### Value Selection Rule

This is the safety-critical proposer rule:

```zig
fn chooseAcceptValue(original: Value, promises: PromiseQuorum) Value {
    return if (promises.highest_seen) |accepted| accepted.value else original;
}
```

The running max in `PromiseQuorum.record` means we don't re-walk responses at quorum time. The filter that prevents stale promises from contaminating value selection lives in `record` — by the time `highest_seen` is read, only votes for the current `bound_to` have ever contributed to it.

`proposeValue(v)` may return a chosen value different from `v`. That is expected Paxos behavior when another value was previously accepted by a quorum member and must be preserved.

## Learner

The learner is the single source of truth for `Effect.chosen`. It accumulates `Accepted` votes into one `AcceptQuorum` per proposal_number, and emits `Effect.chosen` exactly once — on the transition from "no chosen recorded" to "chosen recorded".

```zig
const LearnerState = struct {
    chosen: ?Chosen,
    quorums: Map(ProposalNumber, AcceptQuorum),

    // Termination tracking. Bit i set means peer NodeId i is known to have
    // reached chosen — either because we received `Message.chosen` from them,
    // or (own bit) because we reached chosen ourselves. The node terminates
    // when this bitset is full, or when the retransmit budget is exhausted.
    peers_informed: BitSet,
    chosen_retransmits_remaining: u32,
    chosen_retransmit_timer: ?TimerId,
};
```

Flow:

- acceptor emits `Accepted(n, v)`
- learner gets-or-creates an `AcceptQuorum{ bound_to = n, value = v }` and calls `record(cluster, from, msg)`
- if `quorumReached(cluster)` and `LearnerState.chosen == null`, set `chosen = Chosen{n, v}` and emit `Effect.chosen`

A learner can also reach chosen by receiving `Message.chosen(n, v)` from a peer that has already chosen — same single-emit rule applies. This catch-up path is load-bearing: acceptor-to-learner `Accepted` packets can be lost, so a learner may never collect quorum on its own and would otherwise be stuck forever.

On reaching chosen via either path, the learner hands off to the termination protocol: persist, broadcast `Message.chosen` to all peers, set its own bit in `peers_informed`, start the `chosen_retransmit` timer. See the Termination section.

Note that even though the proposer is co-located with a learner on the same node, only the learner emits `Effect.chosen`. The proposer observes `LearnerState.chosen` and transitions phase; it does not emit a parallel `chosen` effect.

## Termination

A node MUST NOT terminate as soon as its local learner reaches chosen. If multiple nodes terminate unilaterally, the surviving subset can drop below quorum size — and any remaining node that hasn't yet reached chosen is then permanently stuck: no quorum can be assembled to run a fresh round, and no peer is left to query for the value.

Termination is therefore a cluster-wide handshake layered on top of the consensus result. It uses `Message.chosen` as both the dissemination payload and the implicit acknowledgement (a peer that broadcasts `Message.chosen` has, by definition, learned the value).

```zig
const CHOSEN_RETRANSMIT_BUDGET: u32 = 16;
```

`chosen_retransmits_remaining` is initialized to `CHOSEN_RETRANSMIT_BUDGET` when a node first reaches chosen (and reset to it on `recovery_complete`).

Flow:

1. **On reaching local chosen** (via `Accepted` quorum or via `Message.chosen` from a peer):
   - persist `chosen` (see Durable Log)
   - stop initiating new client proposals; subsequent `client_propose` inputs are ignored for the rest of this node's life
   - if `ProposerState.active` is non-null and `active.proposal_number != chosen.proposal_number`, abandon the in-flight attempt (cancel its timers, drop `ActiveProposal`)
   - broadcast `Message.chosen(chosen.proposal_number, chosen.value)` to every peer
   - set own bit in `LearnerState.peers_informed`
   - start a `chosen_retransmit` timer
2. **On receive `Message.chosen` from peer `p`**:
   - if `LearnerState.chosen == null`, set it (same single-emit rule as the Accepted-quorum path) and run step 1 yourself
   - flip bit `p` in `peers_informed` (idempotent under duplicate deliveries)
   - if `peers_informed` is now full, emit `Effect.terminate`
3. **On `chosen_retransmit` timer fire**:
   - if `peers_informed` is full, emit `Effect.terminate`
   - else if `chosen_retransmits_remaining == 0`, emit `Effect.terminate` (a permanently unreachable peer must not freeze the cluster's shutdown)
   - else: rebroadcast `Message.chosen` to every peer whose bit is still unset, decrement `chosen_retransmits_remaining`, restart the timer

`Effect.terminate` is emitted exactly once per node — on the transition from "still tracking peers" to "all peers informed, or budget exhausted." Host runtimes shut the node down on this effect.

The retransmit budget is a deliberate liveness/correctness trade. With the budget, a permanently-failed peer cannot deadlock cluster shutdown; the trade-off is that a node which comes online after the cluster has terminated has no peer left to learn the value from. For a one-process one-instance demo this is acceptable — recovery for late joiners is out of scope (no dynamic membership; see Non-goals).

Acceptors continue to serve `prepare_request` and `accept_request` until `Effect.terminate` fires. The proposer is dormant after local chosen — no fresh proposals, no abandoned-attempt retries.

## Durable Log

The durable log is for protocol recovery. It should be small, structured, and separate from frontend animation traces.

```zig
const DurableLogEntry = union(enum) {
    highest_promised: ProposalNumber,
    accepted: AcceptedProposal,
    highest_proposed_epoch: u64,
    chosen: Chosen,
};
```

Persist before externally visible effects:

- persist `highest_promised` before sending `promise`
- persist `accepted` before sending `accepted`
- persist `highest_proposed_epoch = N` before using epoch `N` in a proposal
- persist `chosen` before broadcasting `Message.chosen` (so dissemination survives a crash)

## Recovery

On startup the runtime replays `DurableLogEntry` records into in-memory state before delivering `Input.recovery_complete`:

- fold `highest_promised` entries to the maximum, store in `AcceptorState.highest_promised`
- fold `accepted` entries; keep the one with the highest `proposal_number`, store in `AcceptorState.accepted`
- fold `highest_proposed_epoch` entries to the maximum; set `ProposerState.next_epoch = max + 1` (the persisted value is the highest epoch ever assigned, so the next safe epoch is one higher)
- fold any `chosen` entry into `LearnerState.chosen`

The core MUST refuse to process `client_propose`, `packet_delivered`, or `timer_fired` until `recovery_complete` has been observed. Servicing protocol inputs against a fresh in-memory state while the truth still sits on disk is a safety violation: a `prepare(n)` arriving on a clean `AcceptorState` would silently override a previously persisted `highest_promised` or `accepted`, letting a proposer choose a different value at a higher number while a previously chosen value sits unread on disk.

`ProposerState.active` is intentionally not persisted. Any in-flight proposal is abandoned across a restart. The next attempt uses a strictly higher `epoch` because `highest_proposed_epoch` was persisted before its value was used.

If `LearnerState.chosen` is set after replay, the node restarts the termination handshake on `recovery_complete`: rebroadcast `Message.chosen`, set own bit in `peers_informed`, reset `chosen_retransmits_remaining` to the configured budget, and start the `chosen_retransmit` timer. Peers will repopulate `peers_informed` as their broadcasts arrive. (`peers_informed` is intentionally not persisted — peer state observed pre-crash may be stale, and the rebroadcast costs little.)

## Trace Log

The trace log is for replay, debugging, and frontend animation. It should not be used as protocol recovery state.

Prefer JSONL so a frontend can stream it:

```json
{"event_id":1,"sim_time":0,"node":1,"role":"proposer","event":"proposal_started","proposal":{"epoch":1,"proposer_id":1},"value":"A","correlation_id":100}
```

The first JSONL record is a one-time `TraceHeader`; all subsequent records are `TraceEvent`s.

Suggested schema:

```zig
const TraceHeader = struct {
    run_id: u32,
    seed: u64,
};

const TraceEvent = struct {
    event_id: u64,
    sim_time_ms: u64,

    node: NodeId,
    role: Role,
    proposal_number: ?ProposalNumber,

    event: TraceEventType,
    packet_id: ?PacketId,
    correlation_id: ?CorrelationId,
    from: ?NodeId,
    to: ?NodeId,

    value: ?Value,
    reason: ?[]const u8,
};

const Role = enum {
    proposer,
    acceptor,
    learner,
    simulator,
};

const TraceEventType = enum {
    proposal_started,
    prepare_sent,
    prepare_delivered,
    highest_promised_persisted,
    promise_sent,
    promise_delivered,
    prepare_rejected,
    prepare_timeout,
    prepare_quorum_reached,
    accepted_value_adopted,
    accept_sent,
    accept_delivered,
    accepted_persisted,
    accepted_sent,
    accepted_delivered,
    accept_rejected,
    accept_timeout,
    accept_quorum_reached,
    proposal_abandoned,
    retry_backoff_started,
    retry_backoff_fired,
    chosen,
    chosen_broadcast_sent,
    peer_chosen_received,
    chosen_retransmit_fired,
    retransmit_budget_exhausted,
    terminated,
    packet_dropped,
    packet_duplicated,
    node_crashed,
    node_restarted,
};
```

For animation, log packet lifecycle events as first-class events:

- packet created
- packet sent
- packet delayed
- packet delivered
- packet dropped
- packet duplicated

The simulator should own network events such as drop, duplicate, and delay. The Paxos node should only emit protocol events and requested sends.

## Timeouts

Timeouts are runtime inputs, not blocking sleeps.

```zig
const TimerKind = enum {
    prepare_timeout,
    accept_timeout,
    retry_backoff,
    chosen_retransmit,
};

const TimerStart = struct {
    id: TimerId,
    node: NodeId,
    // Null for chosen_retransmit (post-consensus; not bound to any proposal).
    proposal_number: ?ProposalNumber,
    kind: TimerKind,
    duration_ms: u64,
};
```

The runtime maps `duration_ms` to its own timer source. In DST, that source is simulated time with deterministic scheduling.

## Public API Shape

The protocol core:

```zig
const NodeLifecycle = enum {
    recovering,   // pre `recovery_complete` — only `recovery_complete` is honored
    running,      // serving inputs normally
    terminated,   // post `Effect.terminate` — all further inputs are ignored
};

const PaxosNode = struct {
    config: ClusterConfig,
    allocator: std.mem.Allocator,
    rng: Rng,                       // seeded by the runtime; protocol never reads system randomness directly

    lifecycle: NodeLifecycle,

    proposer: ProposerState,
    acceptor: AcceptorState,
    learner: LearnerState,

    // Id generators for emitted effects. The protocol owns these because it
    // refers back to ids it generated — e.g., to emit `cancel_timer` for a
    // timer it earlier started, or to dedupe by `correlation_id` at the trace
    // layer.
    next_packet_id: u64,
    next_timer_id: u64,
    next_correlation_id: u64,
    next_trace_event_id: u64,

    pub fn onInput(self: *PaxosNode, input: Input, out: *EffectList) void;
};

// EffectList can be a std.ArrayList(Effect), a bounded array, or any caller-owned append-only buffer used by the runtime/simulator.
// Current implementation: `pub const EffectList = std.ArrayList(Effect);` — the contract still permits a bounded buffer; expect this concrete type to change.
```

`onInput` is a thin dispatcher. It gates on `lifecycle`, then routes by `Input` tag. Pure handlers (`onPrepare`, `onAccept`) take `*AcceptorState` and return a response variant; the dispatcher wraps the response into a `Packet` and emits the corresponding `Effect.send` (and the `Effect.persist` ahead of it where the Durable Log rules require). Cross-role handlers (e.g., handling an incoming `Promise` that may transition the proposer's phase, or an incoming `Message.chosen` that may both set `LearnerState.chosen` *and* abandon a mismatched `ProposerState.active`) are methods on `PaxosNode` because they touch multiple parts of state.

```zig
pub fn onInput(self: *PaxosNode, input: Input, out: *EffectList) void {
    switch (self.lifecycle) {
        .recovering => if (input != .recovery_complete) return,
        .terminated => return,
        .running => {},
    }
    switch (input) {
        .recovery_complete => self.completeRecovery(out),
        .client_propose => |v| self.handleClientPropose(v, out),
        .packet_delivered => |p| self.handlePacket(p, out),
        .timer_fired => |id| self.handleTimerFired(id, out),
    }
}

fn handleTimerFired(self: *PaxosNode, id: TimerId, out: *EffectList) void {
    if (self.proposer.active) |*active| {
        if (active.prepare_timer == id) return self.onPrepareTimeout(active, out);
        if (active.accept_timer == id) return self.onAcceptTimeout(active, out);
        if (active.retry_backoff_timer == id) return self.onRetryBackoff(active, out);
    }
    if (self.learner.chosen_retransmit_timer == id) return self.onChosenRetransmit(out);
    // unknown timer id — stale (cancel/fire race), ignore
}
```

Timer dispatch by id (not by kind) means a stale fire — one whose `cancel_timer` effect raced its `timer_fired` input — is a natural no-op: no slot's id matches, the dispatcher returns silently.

## Deterministic Simulation Contract

The deterministic runtime controls:

- static cluster membership
- message delivery order
- message loss, duplication, delay, and reorder
- node crash and restart
- persisted storage contents
- timers
- random choices through a seed

The same seed reproduces the same event sequence and trace log.

## Safety Invariants

- at most one chosen value exists for an instance
- every chosen value was proposed by some client or adopted from a prior accepted proposal
- learners never learn a value unless quorum accepted it

## References

- Leslie Lamport, [Paxos Made Simple](https://lamport.azurewebsites.net/pubs/paxos-simple.pdf)
- MIT 6.824, [Paxos pseudo-code](https://css.csail.mit.edu/6.824/2014/notes/paxos-code.html)
- MIT 6.824, [Lab 6: Paxos](https://pdos.csail.mit.edu/archive/6.824-2012/labs/lab-6.html)
- FoundationDB, [Simulation and Testing](https://apple.github.io/foundationdb/testing.html)
