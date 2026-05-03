const shared = @import("shared.zig");

const ProposalNumber = shared.ProposalNumber;
const AcceptedProposal = shared.AcceptedProposal;
const Chosen = shared.Chosen;

pub const DurableLogEntry = union(enum) {
    highest_promised: ProposalNumber,
    accepted: AcceptedProposal,
    chosen: Chosen,
    highest_proposed_epoch: u64,
};
