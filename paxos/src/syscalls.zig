//! https://www.openmymind.net/TCP-Server-In-Zig-Part-1-Single-Threaded/ is what I'm looking at
//! after Beejs guide is done.
//!
//! For Network Programming: https://www.cs.cornell.edu/~kvikram/HTMLS/MLA/NET.PDF Beeje's Guide is
//! what I'm looking at. 51 pages.
//!
//! Also for most of the system calls you can use the man pages and if you need more/better
//! explanations you can use the Linux Programming interface book: https://man7.org/tlpi/.
//! It's a great resource.
//! WARNING: If you have the physical copy of the book, don't read it while laying down, it falling
//! on your head can lead to concussions \['']/
//! P.S. It turns out MacsOS has it's own stuff, like everything under the sun. I ended up reading
//! the man pages for both linux and Mac.
//!
//! Zig sockets were removed from the posix in 0.16.0 so I'm just rolling my own wrapper around the
//! c stuff.

// TODO: After the first pass add relevant asserts.

const std = @import("std");
const c = std.c;
const fd_t = std.c.fd_t;
const socket_t = std.c.fd_t;
const max_retires = 8;
const assert = std.debug.assert;

pub const SetNonblockError = error{
    SocketFileDescriptorInvalid,
};

pub const KqueueError = error{
    InsufficientSystemResources,
    ProcessFdLimitExceeded,
    SystemFdLimitExceeded,
};

pub const KeventError = error{
    AddressNotAccessible,
    EventNotFoundOrIsUneditable,
    FileDescriptorInvalid,
    InsufficientSystemResources,
    InvalidArgument,
    PermissionDenied,
    TargetProcessDoesNotExist,
};

pub const SetSockOptError = error{
    AddressNotAccessible,
    InsufficientSystemResources,
    InvalidArgument,
    NotASocket,
    NotSupported,
    OptionValueOutOfBounds,
    SocketAlreadyConnected,
    SocketFileDescriptorInvalid,
};

pub const OpenSocketError = error{
    InsufficientSystemResources,
    PermissionDenied,
    ProcessFdLimitExceeded,
    ProtocolNotSupported,
    SystemFdLimitExceeded,
} || SetNonblockError;

pub const ListenError = error{
    AddressAlreadyInUse,
    AddressFamilyMismatch,
    AddressIsNull,
    AddressLoopBack,
    AddressNotAccessible,
    AddressNotDirectory,
    AddressNotFound,
    AddressNotLocal,
    AddressReadOnly,
    AddressTooLong,
    NotASocket,
    OperationNotSupported,
    PermissionDenied,
    SocketAlreadyBound,
    SocketAlreadyConnected,
    SocketFileDescriptorInvalid,
    SocketNotBound,
} || SetSockOptError || ParseAddressError;

pub const ConnectError = error{
    AddressAlreadyInUse,
    AddressFamilyMismatch,
    AddressLoopBack,
    AddressNotAccessible,
    AddressNotAvailable,
    AddressTooLong,
    AddressTypeMismatch,
    ConnectionAlreadyInProgress,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    FileSystemIoError,
    HostUnreachable,
    InsufficientSystemResources,
    InvalidArgument,
    NamedSocketNotFound,
    NetworkDown,
    NetworkUnreachable,
    NotADirectory,
    NotASocket,
    OperationNotSupported,
    PermissionDenied,
    SocketAlreadyConnected,
    SocketFileDescriptorInvalid,
    WouldBlock,
};

pub const AcceptError = error{
    AddressNotAccessible,
    ConnectionAborted,
    InsufficientSystemResources,
    NotASocket,
    OperationNotSupported,
    ProcessFdLimitExceeded,
    SocketFileDescriptorInvalid,
    SocketNotListening,
    SystemFdLimitExceeded,
    WouldBlock,
} || SetNonblockError;

pub const SendError = error{
    AddressIsNull,
    AddressNotAccessible,
    AddressNotAvailable,
    BrokenPipe,
    ConnectionResetByPeer,
    HostUnreachable,
    InsufficientSystemResources,
    MessageTooLarge,
    NetworkDown,
    NetworkUnreachable,
    NotASocket,
    OperationNotSupported,
    PermissionDenied,
    SocketFileDescriptorInvalid,
    SocketNotConnected,
    WouldBlock,
};

pub const RecvError = error{
    AddressNotAccessible,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    InsufficientSystemResources,
    InvalidArgument,
    NotASocket,
    OperationNotSupported,
    SocketFileDescriptorInvalid,
    SocketNotConnected,
    WouldBlock,
};

pub const ParseAddressError = error{
    InvalidAddress,
};

fn unexpected_errno(label: []const u8, err: c.E) noreturn {
    std.log.err("{s}: unexpected errno .{s}", .{ label, @tagName(err) });
    @panic("unexpected errno");
}

// Trying to recreate a part of the posix interface that was pruned out. And boy do you find more
// respect for such abstractions when you end up building one yourself.
//
// inet_pton sadly is not available so we've got to exten it.
// The actual definition is: inet_pton(inot af, const char *restrict src, void *restrict dst)
//      - af: Address Family
//      - src: Well the source string/representation you want to convert from.
//      - dest: Where the network representation is to be stored.
//      - restrict keyword implies that the src and dst don't have any overlap in memory. I didn't
//        know such a keyword existed :)
// Trivia: It's read as Internet presentation to network.
extern "c" fn inet_pton(af: c_int, src: [*:0]const u8, dst: *anyopaque) c_int;

// Build the network-order sockaddr.in from a IPv4 string
pub fn parse_address(addr: [*:0]const u8, port: u16) ParseAddressError!c.sockaddr.in {
    var addr_network_byte_order: u32 = undefined;
    const pton_res = inet_pton(c.AF.INET, addr, &addr_network_byte_order);
    if (pton_res != 1) {
        return error.InvalidAddress;
    }

    return .{
        .family = c.AF.INET,
        .zero = @splat(0),
        .addr = addr_network_byte_order,
        .port = std.mem.nativeToBig(u16, port),
    };
}

// Since socket is removed from posix and I want to write an event loop for the learning and
// understanding of it, I'll just plug in the c methods and write my own wrapper around them. That
// way I can even pass it around as types, hopefully thats a cleaner abstraction.
//
// And because I need to create from the c api, man pages it is. There's a man page for everything,
// I got a headache reading and comprehending all of them, hats off to the Linux people, maintaining
// such a comprehensive doc system, must have been a lot of work.

/// Open and return a tcp socket in NONBLOCK mode.
pub fn open_socket_tcp(blocking: bool) OpenSocketError!socket_t {
    // AF.INET means we're using an IPv4 Internet protocols
    const socket = try open_socket(c.AF.INET, c.SOCK.STREAM, c.IPPROTO.TCP, blocking);

    return socket;
}

/// Opens a socket given the domain and socket type.
/// Always opens with `NONBLOCK`
fn open_socket(domain: u32, socket_type: u32, protocol: u32, blocking: bool) OpenSocketError!socket_t {
    const socket = c.socket(domain, socket_type, protocol);

    if (socket < 0) {
        return switch (std.c.errno(socket)) {
            .ACCES => error.PermissionDenied,
            // Lumping these together for now, will see if separate errors make sense for these.
            .AFNOSUPPORT, .PROTONOSUPPORT, .PROTOTYPE => error.ProtocolNotSupported,
            .MFILE => error.ProcessFdLimitExceeded,
            .NFILE => error.SystemFdLimitExceeded,
            .NOBUFS, .NOMEM => error.InsufficientSystemResources,
            // According to man the above errors are the only possible ones.
            else => |e| unexpected_errno("open_socket", e),
        };
    }
    errdefer close(socket);

    // For async-io we need the socket to be non-blocking.
    if (!blocking) {
        try set_nonblock(socket);
    }

    return socket;
}

pub fn close(fd: fd_t) void {
    // Fire and forget for now, I don't know if it's possible to handle these errors? From what
    // I see over the internet this seems like a safe bet.
    _ = c.close(fd);
}

// The actual backlog is an i32 for some reason. The backlog length being negative doesn't make
// much sense so I'm just going to prune it to take u31 and cast it at the call site.
// According to the open standard providing a less than 0 value means that the system will take
// some predefined/implementation defined max value which seems just wrong.
//
// If you want to use the SOMAXCONN might as well give backlog as MAX_U31 since in case the
// provided value is greater than the SOMAXCONN, then our value is discarded and it uses the
// SOMAXCONN.
pub fn listen(socket: socket_t, addr: [*:0]const u8, port: u16, backlog: u31) ListenError!void {
    // Quoting the Linux Programming Iterface book.
    // "REUSEADDR: to avoid the EADDRINUSE (“Address already in use”) error when a TCP server is
    // restarted and tries to bind a socket to a port that currently has an associated TCP."
    //
    // Essentially for paxos that I'm trying to achieve it would cut down the restart times
    // since without this the server would have to wait for the timeout during the restart to
    // bring up the same socket again.
    try setsockopt(socket, c.SOL.SOCKET, c.SO.REUSEADDR, 1);

    // TODO: Check if we need to directly accept the sockaddr.in here as well.
    const address = try parse_address(addr, port);

    // All ports under 1024 are reserved and shouldn't be used, if you're dead set on using them
    // you need to be the super user. The program could check the port and shortcircuit early
    // but I don't think that's worth it. The function checks for everything no need to be the
    // superhero :p
    const bind_res = c.bind(socket, @ptrCast(&address), @sizeOf(c.sockaddr.in));

    // I really don't like this, but maybe this is why we've got abstractions so consumers don't
    // have to look at this.
    if (bind_res < 0) {
        return switch (c.errno(bind_res)) {
            .ACCES => error.PermissionDenied,
            .ADDRINUSE => error.AddressAlreadyInUse,
            .ADDRNOTAVAIL => error.AddressNotLocal,
            .AFNOSUPPORT => error.AddressFamilyMismatch,
            .BADF => error.SocketFileDescriptorInvalid,
            .DESTADDRREQ => error.AddressIsNull,
            .FAULT => error.AddressNotAccessible,
            .INVAL => error.SocketAlreadyBound,
            .NOTSOCK => error.NotASocket,
            .OPNOTSUPP => error.OperationNotSupported,
            // According to mac's man page these are UNIX only kept just in case.
            .LOOP => error.AddressLoopBack,
            .NAMETOOLONG => error.AddressTooLong,
            .NOENT => error.AddressNotFound,
            .NOTDIR => error.AddressNotDirectory,
            .ROFS => error.AddressReadOnly,
            else => |e| unexpected_errno("bind", e),
        };
    }

    const listen_res = c.listen(socket, backlog);
    if (listen_res < 0) {
        return switch (c.errno(listen_res)) {
            .ACCES => error.PermissionDenied,
            .BADF => error.SocketFileDescriptorInvalid,
            .DESTADDRREQ => error.SocketNotBound,
            .INVAL => error.SocketAlreadyConnected,
            .NOTSOCK => error.NotASocket,
            .OPNOTSUPP => error.OperationNotSupported,
            else => |e| unexpected_errno("listen", e),
        };
    }
}

pub fn connect(socket: socket_t, address: *const c.sockaddr.in) ConnectError!void {
    for (0..max_retires) |_| {
        const connect_res = c.connect(socket, @ptrCast(address), @sizeOf(c.sockaddr.in));
        if (connect_res >= 0) {
            return;
        }
        switch (c.errno(connect_res)) {
            // Retry the interrupted call; after max_retires interruptions we give up and panic.
            .INTR => continue,
            .ACCES => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressAlreadyInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyMismatch,
            .ALREADY => return error.ConnectionAlreadyInProgress,
            .BADF => return error.SocketFileDescriptorInvalid,
            .CONNREFUSED => return error.ConnectionRefused,
            .FAULT => return error.AddressNotAccessible,
            .HOSTUNREACH => return error.HostUnreachable,
            // WouldBlock to facilitate the IO loop to correctly categorize this as blocking and
            // park it.
            .INPROGRESS => return error.WouldBlock,
            .INVAL => return error.InvalidArgument,
            .ISCONN => return error.SocketAlreadyConnected,
            .NETDOWN => return error.NetworkDown,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOBUFS => return error.InsufficientSystemResources,
            .NOTSOCK => return error.NotASocket,
            .OPNOTSUPP => return error.OperationNotSupported,
            .PROTOTYPE => return error.AddressTypeMismatch,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .CONNRESET => return error.ConnectionResetByPeer,
            // UNIX domain ones
            .IO => return error.FileSystemIoError,
            .LOOP => return error.AddressLoopBack,
            .NAMETOOLONG => return error.AddressTooLong,
            .NOENT => return error.NamedSocketNotFound,
            .NOTDIR => return error.NotADirectory,
            else => |e| unexpected_errno("connect", e),
        }
    }
    @panic("connect: exhausted EINTR retries");
}

pub fn get_socket_error(socket: socket_t) ConnectError!void {
    var sock_err: c_int = undefined;
    var sock_err_len: c.socklen_t = @sizeOf(c_int);
    const res = c.getsockopt(socket, c.SOL.SOCKET, c.SO.ERROR, &sock_err, &sock_err_len);
    if (res < 0) {
        return switch (c.errno(res)) {
            .BADF => error.SocketFileDescriptorInvalid,
            .FAULT => error.AddressNotAccessible,
            .INVAL => error.InvalidArgument,
            .NOTSOCK => error.NotASocket,
            else => |e| unexpected_errno("getsockopt", e),
        };
    }

    if (sock_err == 0) {
        return;
    }

    assert(sock_err >= 0 and sock_err <= std.math.maxInt(u16));

    return switch (@as(c.E, @enumFromInt(sock_err))) {
        .ACCES => error.PermissionDenied,
        .ADDRINUSE => error.AddressAlreadyInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.AddressFamilyMismatch,
        .ALREADY => error.ConnectionAlreadyInProgress,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .INVAL => error.InvalidArgument,
        .ISCONN => error.SocketAlreadyConnected,
        .NETDOWN => error.NetworkDown,
        .NETUNREACH => error.NetworkUnreachable,
        .NOBUFS => error.InsufficientSystemResources,
        .TIMEDOUT => error.ConnectionTimedOut,
        else => |e| unexpected_errno("getsockopt SO_ERROR", e),
    };
}

/// Returns the dedicated socket for that connection. That socket would then be used to read and
/// write for that TCP connecton.
pub fn accept(listen_socket: socket_t, peer: ?*c.sockaddr.in, blocking: bool) AcceptError!socket_t {
    var len: c.socklen_t = @sizeOf(c.sockaddr.in);
    // Write the peer's info the the peer, and writes how many bytes it wrote to peer in the len
    // field. When no peer is requested addrlen must be null too, per the man page.
    for (0..max_retires) |_| {
        const new_socket = c.accept(listen_socket, @ptrCast(peer), if (peer == null) null else &len);
        if (new_socket >= 0) {
            errdefer close(new_socket);

            if (!blocking) {
                try set_nonblock(new_socket);
            }

            return new_socket;
        }
        switch (c.errno(new_socket)) {
            // Retry the interrupted call; after max_retires interruptions we give up and panic.
            .INTR => continue,
            .BADF => return error.SocketFileDescriptorInvalid,
            .CONNABORTED => return error.ConnectionAborted,
            .FAULT => return error.AddressNotAccessible,
            .INVAL => return error.SocketNotListening,
            .MFILE => return error.ProcessFdLimitExceeded,
            .NFILE => return error.SystemFdLimitExceeded,
            .NOMEM => return error.InsufficientSystemResources,
            .NOTSOCK => return error.NotASocket,
            .OPNOTSUPP => return error.OperationNotSupported,
            .AGAIN => return error.WouldBlock,
            else => |e| unexpected_errno("accept", e),
        }
    }
    @panic("accept: exhausted EINTR retries");
}

// Once again we're using u31 because send returns a signed int and well negative numbers are
// errors so the effective range of bytes written to is u31.
/// Returns the number of bytes written/sent and returns an IOError in case of an error.
pub fn send(socket: socket_t, message: []const u8, flags: u32) SendError!u31 {
    // Flags being
    //      MSG_OOB: Process out of band data
    //      MSG_DONTROUTE: Bypass routing, use direct interface.
    // None of which are required for us, so most of the time we'll be sending 0.
    //
    // For tcp `send` can send only some of the data, so keep an eye out for that.
    for (0..max_retires) |_| {
        const send_res = c.send(socket, message.ptr, message.len, flags);
        if (send_res >= 0) {
            return @as(u31, @intCast(send_res));
        }
        switch (c.errno(send_res)) {
            // Retry the interrupted call; after max_retires interruptions we give up and panic.
            .INTR => continue,
            .ACCES => return error.PermissionDenied,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.SocketFileDescriptorInvalid,
            .CONNRESET => return error.ConnectionResetByPeer,
            .DESTADDRREQ => return error.AddressIsNull,
            .FAULT => return error.AddressNotAccessible,
            .HOSTUNREACH => return error.HostUnreachable,
            .MSGSIZE => return error.MessageTooLarge,
            .NETDOWN => return error.NetworkDown,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOBUFS => return error.InsufficientSystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .NOTSOCK => return error.NotASocket,
            .OPNOTSUPP => return error.OperationNotSupported,
            .PIPE => return error.BrokenPipe,
            else => |e| unexpected_errno("send", e),
        }
    }
    @panic("send: exhausted EINTR retries");
}

/// Returns the number of bytes read.
pub fn recv(socket: socket_t, buffer: []u8, flags: u32) RecvError!u31 {
    for (0..max_retires) |_| {
        const recv_res = c.recv(socket, buffer.ptr, buffer.len, @as(c_int, @intCast(flags)));
        if (recv_res >= 0) {
            return @as(u31, @intCast(recv_res));
        }
        switch (c.errno(recv_res)) {
            // After max_retires for interruptions we give up and panic.
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.SocketFileDescriptorInvalid,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => return error.AddressNotAccessible,
            .INVAL => return error.InvalidArgument,
            .NOBUFS => return error.InsufficientSystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .NOTSOCK => return error.NotASocket,
            .OPNOTSUPP => return error.OperationNotSupported,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => |e| unexpected_errno("recv", e),
        }
    }
    @panic("recv: exhausted EINTR retries");
}

fn set_nonblock(socket: socket_t) SetNonblockError!void {
    const get_res = c.fcntl(socket, c.F.GETFL, @as(c_int, 0));
    if (get_res < 0) {
        return switch (c.errno(get_res)) {
            .BADF => error.SocketFileDescriptorInvalid,
            else => |e| unexpected_errno("fcntl_getfl", e),
        };
    }

    var flags: c.O = @bitCast(get_res);
    flags.NONBLOCK = true;

    const set_res = c.fcntl(socket, c.F.SETFL, @as(c_int, @bitCast(flags)));
    if (set_res < 0) {
        return switch (c.errno(set_res)) {
            .BADF => error.SocketFileDescriptorInvalid,
            else => |e| unexpected_errno("fcntl_setfl", e),
        };
    }
}

fn setsockopt(socket: socket_t, level: i32, option: u32, value: c_int) SetSockOptError!void {
    // Option value of 1 means we enable it, 0 means we disable it.
    const res = c.setsockopt(
        socket,
        level,
        option,
        &std.mem.toBytes(value),
        @as(c.socklen_t, @sizeOf(c_int)),
    );

    if (res < 0) {
        return switch (c.errno(res)) {
            .BADF => error.SocketFileDescriptorInvalid,
            .DOM => error.OptionValueOutOfBounds,
            .FAULT => error.AddressNotAccessible,
            .INVAL => error.InvalidArgument,
            .ISCONN => error.SocketAlreadyConnected,
            .NOMEM, .NOBUFS => error.InsufficientSystemResources,
            .NOPROTOOPT => error.NotSupported,
            .NOTSOCK => error.NotASocket,
            else => |e| unexpected_errno("setsockopt", e),
        };
    }
}

pub fn kqueue() KqueueError!fd_t {
    const kq_res = c.kqueue();

    if (kq_res < 0) {
        return switch (c.errno(kq_res)) {
            .NOMEM => error.InsufficientSystemResources,
            .MFILE => error.ProcessFdLimitExceeded,
            .NFILE => error.SystemFdLimitExceeded,
            else => |e| unexpected_errno("kqueue", e),
        };
    }

    return kq_res;
}

test {
    std.testing.refAllDecls(@This());
}

test "open_socket_tcp: returns a usable socket we can close" {
    const socket = try open_socket_tcp(false);
    defer close(socket);
    try std.testing.expect(socket >= 0);
}

test "recv: a bad file descriptor maps to SocketFileDescriptorInvalid" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectError(error.SocketFileDescriptorInvalid, recv(-1, &buffer, 0));
}

test "send: a bad file descriptor maps to SocketFileDescriptorInvalid" {
    try std.testing.expectError(error.SocketFileDescriptorInvalid, send(-1, "ping", 0));
}

test "send/recv: bytes round trip over a connected socket pair" {
    var fds: [2]socket_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds));
    defer close(fds[0]);
    defer close(fds[1]);

    const payload = "ping";
    const wrote = try send(fds[0], payload, 0);
    try std.testing.expectEqual(@as(u31, payload.len), wrote);

    var buffer: [16]u8 = undefined;
    const read = try recv(fds[1], &buffer, 0);
    try std.testing.expectEqualStrings(payload, buffer[0..read]);
}
