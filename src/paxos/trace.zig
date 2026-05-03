const shared = @import("shared.zig");

const NodeId = shared.NodeId;
const PacketId = shared.PacketId;
const Chosen = shared.Chosen;
const ProposalNumber = shared.ProposalNumber;
const CorrelationId = shared.CorrelationId;
const Value = shared.Value;

pub const TraceHeader = struct {
    run_id: u32,
    seed: u64,
};

pub const TraceEvent = struct {
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
