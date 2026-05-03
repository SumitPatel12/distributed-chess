const shared = @import("shared.zig");

const TimerId = shared.TimerId;
const NodeId = shared.NodeId;
const ProposalNumber = shared.ProposalNumber;

pub const TimerKind = enum {
    /// Timeout for when a prepare request is raised. After the timer runs out the prepare is
    /// terminated.
    prepare_timeout,

    /// Timeout for when an accept request is raised. After the timer runs out the accept is
    /// terminated.
    accept_timeout,

    /// Retry a request with a jittered backoff so livelocks if any could be resolved.
    retry_backoff,

    /// Retransmit the chosen message for learners. Used to transmit chosen to learners to bring the
    /// cluster in a consistent state and terminate all processes.
    chosen_retransmit,
};

pub const TimerStart = struct {
    id: TimerId,
    node: NodeId,
    // Null for chosen_retransmit
    proposal_number: ?ProposalNumber,
    kind: TimerKind,
    duration_ms: u64,
};
