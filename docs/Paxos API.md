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

```zig
const NodeId = u32;
const InstanceId = u64;
const TimerId = u64;

const ProposalNumber = struct {
    round: u64,
    proposer_id: NodeId,
};

const Value = []const u8; // Opaque application value.

const AcceptedProposal = struct {
    proposal_number: ProposalNumber,
    value: Value,
};

const ClusterConfig = struct {
    self: NodeId,
    nodes: []const NodeId,

    pub fn quorumSize(self: ClusterConfig) usize {
        return (self.nodes.len / 2) + 1;
    }

    // Maps a NodeId to its position in `nodes`. Quorum trackers use this
    // position as a bitset index, so cluster membership is fixed once
    // ClusterConfig is constructed.
    pub fn indexOf(self: ClusterConfig, node: NodeId) ?usize {
        for (self.nodes, 0..) |n, i| {
            if (n == node) {
                return i;
            }
        }
        return null;
    }
};
```

`ProposalNumber` is ordered lexicographically:

1. higher `round` wins
2. if rounds are equal, higher `proposer_id` wins

This gives each proposer a disjoint proposal-number space while keeping proposal numbers easy to compare.

## Runtime Boundary

The protocol core should not block on sockets, sleep, read system time, or call randomness directly. Instead, it handles deterministic inputs and returns effects for the runtime or simulator to execute.

```zig
const Input = union(enum) {
    client_propose: Value,
    message_delivered: Envelope,
    timer_fired: TimerId,
    recovery_complete,
};

const Effect = union(enum) {
    send: Envelope,
    start_timer: TimerStart,
    cancel_timer: TimerId,
    persist: DurableLogEntry,
    emit_trace: TraceEvent,
    chosen: Chosen,
};

fn onInput(node: *PaxosNode, input: Input, out: *EffectList) void;
```

Host runtimes drive this event loop until they observe `chosen` or timeout. Deterministic simulation drives the same core with simulated time, seeded randomness, and a simulated network.

## Messages

Every network message should be wrapped in an envelope so logs can preserve causality.

```zig
const MessageId = u64;
const CorrelationId = u64;

const Envelope = struct {
    id: MessageId,
    correlation_id: CorrelationId,
    from: NodeId,
    to: NodeId,
    instance_id: InstanceId,
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
    next_round: u64,
    active: ?ActiveProposal,
};

// Bound to a single proposal attempt. Inserts whose proposal_number does not
// match `bound_to` are rejected at the boundary, so a delayed message from an
// abandoned round cannot bleed into the current round's quorum count.
//
// Voters are tracked by their position in `ClusterConfig.nodes`, which gives a
// fixed-size bitset: no allocation, deterministic iteration, popcount for size,
// idempotent under duplicate deliveries.
const PromiseQuorum = struct {
    bound_to: ProposalNumber,
    received: BitSet,                     // bit i set => ClusterConfig.nodes[i] has voted
    highest_seen: ?AcceptedProposal,      // running max of highest_accepted across voters

    fn record(self: *PromiseQuorum, cluster: ClusterConfig, from: NodeId, msg: Promise) bool {
        if (!ProposalNumber.eql(msg.proposal_number, self.bound_to)) return false;
        const idx = cluster.indexOf(from) orelse return false;
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
        const idx = cluster.indexOf(from) orelse return false;
        if (self.received.isSet(idx)) return false;
        self.received.set(idx);
        return true;
    }

    fn quorumReached(self: AcceptQuorum, cluster: ClusterConfig) bool {
        return self.received.count() >= cluster.quorumSize();
    }
};

const ActiveProposal = struct {
    instance_id: InstanceId,
    proposal_number: ProposalNumber,
    original_value: Value,
    chosen_accept_value: ?Value,
    phase: Phase,
    promises: PromiseQuorum,
    highest_rejection: ?ProposalNumber,
};

const Phase = enum {
    idle,
    preparing,
    accepting,
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
9. On timeout, or once quorum is impossible (more than half the cluster has rejected), abandon the active proposal and retry with a proposal number higher than `highest_rejection` and higher than any number this proposer has used before.

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
};
```

Flow:

- acceptor emits `Accepted(n, v)`
- learner gets-or-creates an `AcceptQuorum{ bound_to = n, value = v }` and calls `record(cluster, from, msg)`
- if `quorumReached(cluster)` and `LearnerState.chosen == null`, set `chosen = Chosen{n, v}` and emit `Effect.chosen`

If a learner receives `Message.chosen` from another learner (the distinguished-learner shortcut), it can set `chosen` directly without waiting for the accept votes. Same single-emit rule applies.

Note that even though the proposer is co-located with a learner on the same node, only the learner emits `Effect.chosen`. The proposer observes `LearnerState.chosen` and transitions phase; it does not emit a parallel `chosen` effect.

## Durable Log

The durable log is for protocol recovery. It should be small, structured, and separate from frontend animation traces.

```zig
const DurableLogEntry = union(enum) {
    highest_promised: struct {
        instance_id: InstanceId,
        proposal_number: ProposalNumber,
    },
    accepted: struct {
        instance_id: InstanceId,
        proposal_number: ProposalNumber,
        value: Value,
    },
    proposer_round: struct {
        next_round: u64,
    },
    chosen: struct {
        instance_id: InstanceId,
        proposal_number: ProposalNumber,
        value: Value,
    },
};
```

Persist before externally visible effects:

- persist `highest_promised` before sending `promise`
- persist `accepted` before sending `accepted`
- persist proposer round before using a proposal number

## Recovery

On startup the runtime replays `DurableLogEntry` records into in-memory state before delivering `Input.recovery_complete`:

- fold `highest_promised` entries to the maximum, store in `AcceptorState.highest_promised`
- fold `accepted` entries; keep the one with the highest `proposal_number`, store in `AcceptorState.accepted`
- fold `proposer_round` entries to the maximum, store in `ProposerState.next_round`
- fold any `chosen` entry into `LearnerState.chosen`

The core MUST refuse to process `client_propose`, `message_delivered`, or `timer_fired` until `recovery_complete` has been observed. Servicing protocol inputs against a fresh in-memory state while the truth still sits on disk is a safety violation: a `prepare(n)` arriving on a clean `AcceptorState` would silently override a previously persisted `highest_promised` or `accepted`, letting a proposer choose a different value at a higher number while a previously chosen value sits unread on disk.

`ProposerState.active` is intentionally not persisted. Any in-flight proposal is abandoned across a restart. The next attempt uses a strictly higher `round` because `next_round` was persisted before its previous value was ever used.

## Trace Log

The trace log is for replay, debugging, and frontend animation. It should not be used as protocol recovery state.

Prefer JSONL so a frontend can stream it:

```json
{"event_id":1,"sim_time":0,"node":1,"role":"proposer","event":"proposal_started","instance":0,"proposal":{"round":1,"proposer_id":1},"value":"A","correlation_id":100}
```

Suggested schema:

```zig
const TraceEvent = struct {
    event_id: u64,
    run_id: []const u8,
    seed: u64,
    sim_time_ms: u64,

    node: NodeId,
    role: Role,
    instance_id: InstanceId,
    proposal_number: ?ProposalNumber,

    event: TraceEventType,
    message_id: ?MessageId,
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
    chosen,
    message_dropped,
    message_duplicated,
    node_crashed,
    node_restarted,
};
```

For animation, log message lifecycle events as first-class events:

- message created
- message sent
- message delayed
- message delivered
- message dropped
- message duplicated

The simulator should own network events such as drop, duplicate, and delay. The Paxos node should only emit protocol events and requested sends.

## Timeouts

Timeouts are runtime inputs, not blocking sleeps.

```zig
const TimerKind = enum {
    prepare_timeout,
    accept_timeout,
    retry_backoff,
};

const TimerStart = struct {
    id: TimerId,
    node: NodeId,
    instance_id: InstanceId,
    proposal_number: ProposalNumber,
    kind: TimerKind,
    duration_ms: u64,
};
```

The runtime maps `duration_ms` to its own timer source. In DST, that source is simulated time with deterministic scheduling.

## Public API Shape

The protocol core:

```zig
const PaxosNode = struct {
    config: ClusterConfig,
    proposer: ProposerState,
    acceptor: AcceptorState,
    learner: LearnerState,

    pub fn onInput(self: *PaxosNode, input: Input, out: *EffectList) void;
};

// EffectList can be a std.ArrayList(Effect), a bounded array, or any caller-owned append-only buffer used by the runtime/simulator.
```

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
