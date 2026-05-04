const std = @import("std");
const shared = @import("shared.zig");
const messages = @import("messages.zig");
const timer = @import("timer.zig");
const durable_log = @import("durable_log.zig");
const trace = @import("trace.zig");
const acceptor = @import("acceptor.zig");
const proposer = @import("proposer.zig");
const learner = @import("learner.zig");

const Value = shared.Value;
const TimerId = shared.TimerId;
const ClusterConfig = shared.ClusterConfig;
const Chosen = shared.Chosen;
const Packet = messages.Packet;
const TimerStart = timer.TimerStart;
const DurableLogEntry = durable_log.DurableLogEntry;
const TraceEvent = trace.TraceEvent;
const AcceptorState = acceptor.AcceptorState;
const ProposerState = proposer.ProposerState;
const LearnerState = learner.LearnerState;

pub const Input = union(enum) {
    client_propose: Value,
    packet_delivered: Packet,
    timer_fired: TimerId,
    recovery_complete,
};

pub const Effect = union(enum) {
    send: Packet,
    start_timer: TimerStart,
    cancel_timer: TimerId,
    persist: DurableLogEntry,
    emit_trace: TraceEvent,
    chosen: Chosen,
    terminate,
};

// EffectList is the caller-owned append-only buffer the dispatcher pushes effects into.
// We use std.ArrayList(Effect) for now; this may change to a bounded buffer later.
pub const EffectList = std.ArrayList(Effect);

pub const NodeLifecycle = enum {
    recovering,
    running,
    terminated,
};

pub const PaxosNode = struct {
    config: ClusterConfig,
    acceptor: AcceptorState,
    proposer: ProposerState,
    learner: LearnerState,

    pub fn on_input(self: *PaxosNode, input: Input, out: *EffectList) void {
        _ = self;
        _ = input;
        _ = out;
    }

    // TODO: Wire up function
    pub fn handle_timer_fired(self: *PaxosNode, id: TimerId, out: *EffectList) void {
        _ = self;
        _ = id;
        _ = out;
    }
};
