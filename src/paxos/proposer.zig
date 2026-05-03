const shared = @import("shared.zig");
const bitset = @import("bitset.zig");
const messages = @import("messages.zig");

const ProposalNumber = shared.ProposalNumber;
const Value = shared.Value;
const TimerId = shared.TimerId;
const NodeId = shared.NodeId;
const ClusterConfig = shared.ClusterConfig;
const AcceptedProposal = shared.AcceptedProposal;
const Promise = messages.Promise;
const BitSet = bitset.BitSet;

pub const ProposerState = struct {
    next_epoch: u64,
    active: ?ActiveProposal,
};

/// For a given proposal, tracks the repsonses form acceptors. Promises that don't match `bount_to`
/// are rejected, this avoids scenrios where a delayed promise would otherwise interfere with the
/// the current attempt's quorum.
///
/// Additionally keeps track of the highest_accepted proposals that acceptors reply with.
const PromiseQuorum = struct {
    bound_to: ProposalNumber,
    received: BitSet,
    highest_seen: ?AcceptedProposal,

    // TODO: Wire up the actual method.
    fn record(self: *PromiseQuorum, cluster: ClusterConfig, from: NodeId, msg: Promise) bool {
        _ = self;
        _ = cluster;
        _ = from;
        _ = msg;
        return false;
    }

    fn quorum_reached(self: *const PromiseQuorum, cluster: ClusterConfig) bool {
        return self.received.count() >= cluster.quorum_size();
    }
};

pub const ActiveProposal = struct {
    proposal_number: ProposalNumber,
    original_value: Value,
    chosen_accepted_value: ?Value,
    phase: Phase,
    promises: PromiseQuorum,
    highest_rejection: ?ProposalNumber,

    // At a given time only one of these timers are active. Prepare and accept times correspond to
    // corresponding phases.
    // retry_backoff_timer is for when the system is in a potential livelock. The proposer enters a
    // backoff jitter to break it.
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
