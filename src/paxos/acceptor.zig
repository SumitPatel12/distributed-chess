const shared = @import("shared.zig");
const messages = @import("messages.zig");

const ProposalNumber = shared.ProposalNumber;
const AcceptedProposal = shared.AcceptedProposal;
const PrepareRequest = messages.PrepareRequest;
const PrepareResponse = messages.PrepareResponse;
const AcceptRequest = messages.AcceptRequest;
const AcceptResponse = messages.AcceptResponse;

pub const AcceptorState = struct {
    highest_promised: ?ProposalNumber,
    accepted: ?AcceptedProposal,

    pub fn highest_accepted_less_than(
        self: AcceptorState,
        incoming_proposal_number: ProposalNumber,
    ) ?AcceptedProposal {
        if (self.accepted) |accepted_proposal| {
            if (accepted_proposal.proposal_number.is_less_than(incoming_proposal_number)) {
                return accepted_proposal;
            }
        }

        return null;
    }
};

/// Handles the prepare reuqest for an acceptor given the state.
/// When the request is accepted, updates the state.highest_promised with the request.
pub fn handle_prepare(state: *AcceptorState, request: PrepareRequest) PrepareResponse {
    // TODO: Add Trace events, if required.
    if (state.highest_promised == null or
        state.highest_promised.?.is_less_than(request.proposal_number))
    {
        state.highest_promised = request.proposal_number;

        // TODO: Perist to log.

        return .{
            .promise = .{
                .proposal_number = request.proposal_number,
                .highest_accepted = state.highest_accepted_less_than(request.proposal_number),
            },
        };
    }

    // The prior if alreads ensures that state is non null at this point.
    // If it was a duplicate request we just give it the promise.
    if (request.proposal_number.equals(state.highest_promised.?)) {
        // No need to perist since this is a duplicate.
        return .{ .promise = .{
            .proposal_number = request.proposal_number,
            .highest_accepted = state.highest_accepted_less_than(request.proposal_number),
        } };
    }

    // We've already checked the two success scenarios if we reach here it's failed.
    return .{
        .prepare_rejected = .{
            .proposal_number = request.proposal_number,
            .highest_promised = state.highest_promised.?,
        },
    };
}

pub fn handle_accept(state: *AcceptorState, request: AcceptRequest) AcceptResponse {
    // TODO: Handle trace events if any.
    // Accept when we've made no promise yet, or the request's proposal_number is >= our promise.
    // `!is_less_than` gives us `>=` since proposal numbers are totally ordered.
    if (state.highest_promised == null or
        !request.proposal_number.is_less_than(state.highest_promised.?))
    {
        state.highest_promised = request.proposal_number;
        state.accepted = .{
            .proposal_number = request.proposal_number,
            .value = request.value,
        };
        // TODO: Perist log

        return .{
            .accepted = .{
                .proposal_number = request.proposal_number,
                .value = request.value,
            },
        };
    }

    return .{
        .accept_rejected = .{
            .proposal_number = request.proposal_number,
            .highest_promised = state.highest_promised.?,
        },
    };
}
