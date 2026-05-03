const shared = @import("shared.zig");
const bitset = @import("bitset.zig");

const Chosen = shared.Chosen;
const TimerId = shared.TimerId;
const BitSet = bitset.BitSet;

pub const LearnerState = struct {
    chosen: ?Chosen,
    // TODO: Add quorums to track each proposals quorum state.
    // quorums: SomeMap<ProposalNumber, AcceptedQuorum)

    peers_informed: BitSet,
    chosen_retransmits_remaining: u32,
    chosen_retransmit_timer: ?TimerId,
};
