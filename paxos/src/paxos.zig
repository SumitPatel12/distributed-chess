const std = @import("std");

pub const IO = @import("io.zig").IO;
pub const syscalls = @import("syscalls.zig");

/// Proposal number is a u64 made of two parts, the upper 56 bits are used for the epoch number and
/// the lower 8 bits are used for node_id/node index. This way we can have direct comparisions
/// wihtout having special functions for comparisions. (I had that before, and believe me that's not
/// something you'd want to do).
const ProposalNumber = u64;

const ProposalNumberHelper = struct {
    // Turns out you can't have a function parameter and a function with the same name inside of a
    // struct scope, i.e. you can't name init(epoch: u56, node_id: u8), because the names epoch and
    // node_id clash with the function names. Not a big fan of this one.
    pub fn init(epoch_: u56, node_id_: u8) ProposalNumber {
        return (@as(ProposalNumber, epoch_) << 8) | @as(ProposalNumber, node_id_);
    }

    // Returns the node_id for the given proposal number. The lower 8 bits.
    pub fn node_id(value: ProposalNumber) u8 {
        return @truncate(value);
    }

    // Returns the epoch for the given proposal number. The upper 56 bits.
    pub fn epoch(value: ProposalNumber) u56 {
        return @intCast(value >> 8);
    }
};

// Some of the comments seem redundant, but believe me, unless you work with Paxos every day,
// there's a good chance you'll forget a couple of things, these redundant comments help a lot.

const AcceptedProposal = struct {
    proposal_number: ProposalNumber,
    value: u64,
};

const Prepare = struct {
    proposal_number: ProposalNumber,
};

/// The sender promises to not accept any proposal numbers lesser than the specified one.
const Promise = struct {
    proposal_number: ProposalNumber,

    /// The sender has accepted a proposal number and value already and is therefore promising to
    /// not accept greater than specified proposal number while also sending back it's accepted
    /// proposal number and value for the preprator to use.
    accepted: ?AcceptedProposal,
};

/// Preprator got the majority and now asks the peers to accept the proposal number and associated
/// value.
const Accept = struct {
    proposal_number: ProposalNumber,
    value: u64,
};

/// Sender has accepted the proposal number.
const Accepted = struct {
    proposal_number: ProposalNumber,
    value: u64,
};

/// Sender has already promised to not accepte proposal numbers lower than specified proposal
/// number and thus rejects the request.
const Nack = struct {
    proposal_number: ProposalNumber,
    highest_promised: ProposalNumber,
};

const PaxosMessage = union(enum) {
    prepare: Prepare,
    promise: Promise,
    accept: Accept,
    accepted: Accepted,
    nack: Nack,
};

test "proposal number helper" {
    const number = ProposalNumberHelper.init(1, 1);

    try std.testing.expectEqual(@as(ProposalNumber, 0x0000_0000_0000_0101), number);
    try std.testing.expectEqual(@as(u56, 1), ProposalNumberHelper.epoch(number));
    try std.testing.expectEqual(@as(u8, 1), ProposalNumberHelper.node_id(number));
}

test "proposal number comparisions" {
    const number = ProposalNumberHelper.init(1, 1);
    const number2 = ProposalNumberHelper.init(1, 2);
    const number3 = ProposalNumberHelper.init(2, 1);
    const number4 = ProposalNumberHelper.init(2, 1);

    try std.testing.expect(number < number2);
    try std.testing.expect(number2 < number3);
    try std.testing.expect(number3 == number4);
}

test {
    _ = @import("io.zig");
    _ = @import("queue.zig");
    _ = @import("clock.zig");
    _ = @import("syscalls.zig");
    _ = @import("message_bus.zig");
    _ = @import("ring_buffer.zig");
    _ = @import("message.zig");
    _ = @import("node.zig");
}
