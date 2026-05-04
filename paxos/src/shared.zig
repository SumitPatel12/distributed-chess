const bitset = @import("bitset.zig");
const build_options = @import("build_options");

const BitSet = bitset.BitSet;

// It starts to get difficult to reason about things so we're using this hack to give type aliases
// to make the implementation more legible.
pub const NodeId = enum(u32) { _ };
pub const PacketId = enum(u64) { _ };
pub const TimerId = enum(u64) { _ };
pub const CorrelationId = enum(u64) { _ };

const build_cluster_size: u32 = build_options.cluster_size;
pub const NodeBitSet = BitSet(u64, build_cluster_size);

pub const ClusterConfig = struct {
    /// Current Nodes Id
    id: NodeId,

    /// Cluster contains exactly size number of nodes, is configured when the node is brought up.
    pub const cluster_size = build_cluster_size;
    pub const quorum_size = (cluster_size / 2) + 1;
};

/// Value that the Paxos cluster is trying to reach consensus for.
pub const Value = struct { bytes: []const u8 };

/// Proposal number that drives the prepare and accept phases.
/// Carris `epoch` and `proposer_id`.
///
/// Higher `epoch` wins, in case of same epoch number the one with the higher `proposer_id` wins.
pub const ProposalNumber = struct {
    /// The monotonically increasing sequence number.
    epoch: u64,
    /// The identifier of the node that raised the proposal number.
    proposer_id: NodeId,

    /// Verifies if the proposal number is less than the target.
    /// If epoch is greater than that proposal is greater.
    /// If epoch is equal then the proposal with the higher proposer_id is greater.
    /// If epoch is lesser than the proposal is lesser.
    pub fn is_less_than(self: ProposalNumber, target: ProposalNumber) bool {
        if (self.epoch != target.epoch) {
            return self.epoch < target.epoch;
        }
        return @intFromEnum(self.proposer_id) < @intFromEnum(target.proposer_id);
    }

    /// Two proposal numbers are equal iff both their epoch and proposer_id match.
    pub fn equals(self: ProposalNumber, target: ProposalNumber) bool {
        return self.epoch == target.epoch and self.proposer_id == target.proposer_id;
    }
};

// Is used for both Acceptor state and to send over the netowrk hence why a part of shared.
// The one's that are only to be shared over the netwrok are present in the `messages.zig` file.
/// Stores the data pertaining to the last accepted proposal of the node.
pub const AcceptedProposal = struct {
    proposal_number: ProposalNumber,
    value: Value,
};

/// Carries the chosen value once the cluster reaches consensus.
pub const Chosen = struct {
    proposal_number: ProposalNumber,
    value: Value,
};
