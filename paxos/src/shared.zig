const std = @import("std");
const bitset = @import("bitset.zig");
const build_options = @import("build_options");

const BitSet = bitset.BitSet;

// It starts to get difficult to reason about things so we're using this hack to give type aliases
// to make the implementation more legible.
pub const NodeId = enum(u8) { _ };
pub const PacketId = enum(u64) { _ };
pub const TimerId = enum(u64) { _ };
pub const CorrelationId = enum(u64) { _ };
pub const ProposalNumber = u32;

const build_cluster_size: u32 = build_options.cluster_size;
pub const NodeBitSet = BitSet(u64, build_cluster_size);
pub const MAX_CHOSEN_RETRIES: u32 = 256;

pub const ClusterConfig = struct {
    /// Current Nodes Id
    id: NodeId,

    pub const cluster_size = build_cluster_size;
    pub const quorum_size = (cluster_size / 2) + 1;
};

/// Value that the Paxos cluster is trying to reach consensus for.
pub const Value = struct { bytes: []const u8 };

/// Proposal number is a u32 made of two parts, the upper 24 bits are used for the epoch number and
/// the lower 8 bits are used for node_id/node index. This way we can have direct
/// comparisions wihtout having special functions for comparisions. (I had that before, and believe
/// me that's not something you'd want to do).
pub const ProposalNumberHelper = struct {
    // Turns out you can't have the same function parameter name and a function named the same
    // within the same struct, i.e. you can't name init(epoch: u24, node_id: NodeId), because the
    // names epoch and node_id clash with the function names. Not a big fan of this one.
    pub fn init(ep: u24, n_id: NodeId) ProposalNumber {
        const u8_node_id: u8 = @intFromEnum(n_id);
        return (@as(u32, ep) << 8) | @as(u32, u8_node_id);
    }

    // Returns the node_id for the given proposal number. The lower 8 bits.
    pub fn node_id(value: ProposalNumber) NodeId {
        // You can't directly do @enumFromInt(@truncate(value)) cause @truncate needs to know the
        // target value via inference and that's not possible the aforementioned nesting.
        const u8_node_id: u8 = @truncate(value);
        return @enumFromInt(u8_node_id);
    }

    // Returns the node_id for the given proposal number. The upper 24 bits.
    pub fn epoch(value: ProposalNumber) u24 {
        return @intCast(value >> 8);
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

// --- Tests ---------------------------------------------------------------------------------------
test "proposal number helper" {
    const number = ProposalNumberHelper.init(1, @enumFromInt(1));

    try std.testing.expectEqual(@as(ProposalNumber, 0b00000000_00000000_00000001_00000001), number);
    try std.testing.expectEqual(@as(u24, 0b00000000_00000000_00000001), ProposalNumberHelper.epoch(number));
    try std.testing.expectEqual(@as(NodeId, @enumFromInt(0b00000001)), ProposalNumberHelper.node_id(number));
}

test "proposal number comparisions" {
    const node1_id: NodeId = @enumFromInt(1);
    const node2_id: NodeId = @enumFromInt(2);

    const number = ProposalNumberHelper.init(1, node1_id);
    const number2 = ProposalNumberHelper.init(1, node2_id);
    const number3 = ProposalNumberHelper.init(2, node1_id);
    const number4 = ProposalNumberHelper.init(2, node1_id);

    try std.testing.expect(number < number2);
    try std.testing.expect(number2 < number3);
    try std.testing.expect(number3 == number4);
}
