const shared = @import("shared.zig");

const ProposalNumber = shared.ProposalNumber;
const Value = shared.Value;
const PacketId = shared.PacketId;
const CorrelationId = shared.CorrelationId;
const NodeId = shared.NodeId;
const AcceptedProposal = shared.AcceptedProposal;
const Chosen = shared.Chosen;

pub const Packet = struct {
    id: PacketId,
    correlation_id: CorrelationId,
    from: NodeId,
    to: NodeId,
    message: Message,
};

pub const Message = union(enum) {
    prepare_request: PrepareRequest,
    promise: Promise,
    prepare_rejected: PrepareRejected,

    accept_request: AcceptRequest,
    accepted: Accepted,
    accept_rejected: AcceptRejected,

    chosen: Chosen,
};

pub const PrepareRequest = struct { proposal_number: ProposalNumber };

pub const PrepareRejected = struct {
    proposal_number: ProposalNumber,
    highest_promised: ProposalNumber,
};

pub const Promise = struct { proposal_number: ProposalNumber, highest_accepted: ?AcceptedProposal };

pub const PrepareResponse = union(enum) {
    promise: Promise,
    prepare_rejected: PrepareRejected,
};

pub const AcceptRequest = struct {
    proposal_number: ProposalNumber,
    value: Value,
};

pub const AcceptRejected = struct {
    proposal_number: ProposalNumber,
    highest_promised: ProposalNumber,
};

pub const Accepted = struct {
    proposal_number: ProposalNumber,
    value: Value,
};

pub const AcceptResponse = union(enum) {
    accepted: Accepted,
    accept_rejected: AcceptRejected,
};
