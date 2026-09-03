const std = @import("std");
const crc32c = @import("crc32_c.zig").crc32c;

pub const MessageType = enum(u8) {
    prepare,
    promise,
    accept,
    accepted,
    nack,
};

/// 32 byte fixed size message, with an 8 byte header, and 24 byte body. In case the body payload is
/// smaller than 24 bytes, it'll be padded with zeros.
/// Header:
///  - 4 byte CRC32-C checksum
///  - 2 byte SenderId
///  - 1 byte MyssageType
///  - 1 byte Version
///  - Body will be decided by message type
pub const Message = struct {
    message_type: MessageType,
    body: [body_size]u8 = std.mem.zeroes([body_size]u8),
    sender: u16,

    pub const protocol_version: u8 = 1;
    pub const size: usize = 32;
    pub const header_size: usize = 8;
    // You could use max_body size, but this one here is fixed, body will always be 24 if the actual
    // payload is smaller we pad it. So, body_size remains the better option, imo.
    pub const body_size: usize = 24;

    const Self = @This();

    pub fn init(message_type: MessageType, body: []const u8, sender: u16) Self {
        std.debug.assert(body.len <= body_size);
        var message: Self = .{
            .message_type = message_type,
            .sender = sender,
        };

        @memcpy(message.body[0..body.len], body);
        return message;
    }

    pub fn encode(self: Self, out: *[size]u8) void {
        std.mem.writeInt(u16, out[4..6], self.sender, .little);
        out[6] = @intFromEnum(self.message_type);
        out[7] = protocol_version;
        @memcpy(out[8..size], &self.body);

        std.mem.writeInt(u32, out[0..4], crc32c(out[4..]), .little);
    }

    pub fn decode(buffer: *const [size]u8) !Self {
        const checksum = crc32c(buffer[4..]);
        const wire_checksum = std.mem.readInt(u32, buffer[0..4], .little);
        if (wire_checksum != checksum) {
            return error.ChecksumMismatch;
        }

        const sender = std.mem.readInt(u16, buffer[4..6], .little);
        const message_type = std.enums.fromInt(MessageType, buffer[6]) orelse
            return error.InvalidMessageType;

        if (protocol_version != buffer[7]) {
            return error.UnsupportedVersion;
        }

        return .{
            .sender = sender,
            .message_type = message_type,
            .body = buffer[8..].*,
        };
    }
};

test "Message: encode/decode round-trips" {
    var body: [Message.body_size]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = @intCast(i & 0xff);
    const msg: Message = .{ .message_type = .promise, .sender = 3, .body = body };

    var wire: [Message.size]u8 = undefined;
    msg.encode(&wire);
    try std.testing.expectEqual(@as(usize, 32), wire.len);
    try std.testing.expectEqual(Message.protocol_version, wire[7]);

    const decoded = try Message.decode(&wire);
    try std.testing.expectEqual(MessageType.promise, decoded.message_type);
    try std.testing.expectEqual(@as(u16, 3), decoded.sender);
    try std.testing.expectEqualSlices(u8, &body, &decoded.body);
}

test "Message: init sets fields and round-trips" {
    var body: [Message.body_size]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = @intCast(i & 0xff);
    const msg = Message.init(.accepted, &body, 9);

    try std.testing.expectEqual(MessageType.accepted, msg.message_type);
    try std.testing.expectEqual(@as(u16, 9), msg.sender);
    try std.testing.expectEqualSlices(u8, &body, &msg.body);

    var wire: [Message.size]u8 = undefined;
    msg.encode(&wire);
    const decoded = try Message.decode(&wire);
    try std.testing.expectEqual(MessageType.accepted, decoded.message_type);
    try std.testing.expectEqual(@as(u16, 9), decoded.sender);
    try std.testing.expectEqualSlices(u8, &body, &decoded.body);
}

test "Message: init zero-pads a short body" {
    const partial = [_]u8{ 0xaa, 0xbb, 0xcc };
    const msg = Message.init(.prepare, &partial, 1);

    try std.testing.expectEqualSlices(u8, &partial, msg.body[0..partial.len]);
    for (msg.body[partial.len..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "crc32c matches the standard check value" {
    try std.testing.expectEqual(@as(u32, 0xE3069283), crc32c("123456789"));
}

test "Message: decode rejects an unknown type byte" {
    var wire: [Message.size]u8 = undefined;
    @memset(&wire, 0);
    wire[7] = Message.protocol_version;
    wire[6] = 0xEE;
    std.mem.writeInt(u32, wire[0..4], crc32c(wire[4..]), .little);
    try std.testing.expectError(error.InvalidMessageType, Message.decode(&wire));
}

test "Message: decode rejects an unsupported version" {
    var wire: [Message.size]u8 = undefined;
    @memset(&wire, 0);
    wire[6] = @intFromEnum(MessageType.prepare);
    wire[7] = 0xEE;
    std.mem.writeInt(u32, wire[0..4], crc32c(wire[4..]), .little);
    try std.testing.expectError(error.UnsupportedVersion, Message.decode(&wire));
}

test "Message: decode rejects a corrupted frame" {
    const body: [Message.body_size]u8 = @splat(0);
    const msg: Message = .{ .message_type = .accept, .sender = 7, .body = body };
    var wire: [Message.size]u8 = undefined;
    msg.encode(&wire);
    wire[10] ^= 0xFF;
    try std.testing.expectError(error.ChecksumMismatch, Message.decode(&wire));
}
