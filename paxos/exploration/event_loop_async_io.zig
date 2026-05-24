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
const socket_t = std.c.fd_t;

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

// Since socket is removed from posix and I want to write an event loop for the learning and
// understanding of it, I'll just plug in the c methods and write my own wrapper around them. That
// way I can even pass it around as types, hopefully thats a cleaner abstraction.
//
// And because I need to create from the c api, man pages it is. There's a man page for everything,
// I got a headache reading and comprehending all of them, hats off to the Linux people, maintaining
// such a comprehensive doc system, must have been a lot of work.
//
// TODO: I think unreachable in the error is not a really great idea, if I miss something and that
// pops up, the system crashes with unreachable, we want the system to crash, we just don't want to
// lose data just because I marked it as unreachable. Likely make it some kind of unexpected error
// and log out it's error no, that would be the best idea imo.

/// Network IO for macos.
const IO = struct {
    const IOError = error{
        AddressAlreadyInUse,
        AddressFamilyMismatch,
        AddressIsNull,
        AddressLoopBack,
        AddressNotAccessible,
        AddressNotAvailable,
        AddressNotDirectory,
        AddressNotFound,
        AddressNotLocal,
        AddressReadOnly,
        AddressTooLong,
        AddressTypeMismatch,
        BrokenPipe,
        ConnectionAborted,
        ConnectionAlreadyInProgress,
        ConnectionInProgress,
        ConnectionRefused,
        ConnectionResetByPeer,
        ConnectionTimedOut,
        FileSystemIoError,
        HostUnreachable,
        InsufficientSystemResources,
        InterruptedBySignal,
        InvalidArgument,
        MessageTooLarge,
        NamedSocketNotFound,
        NetworkDown,
        NetworkUnreachable,
        NotADirectory,
        NotASocket,
        NotSupported,
        OperationNotSupported,
        OptionValueOutOfBounds,
        PermissionDenied,
        ProcessFdLimitExceeded,
        ProtocolNotSupported,
        SocketAlreadyBound,
        SocketAlreadyConnected,
        SocketFileDescriptorInvalid,
        SocketNotBound,
        SocketNotConnected,
        SocketNotListening,
        SystemFdLimitExceeded,
        WouldBlock,
    };

    /// Open and return a tcp socket in NONBLOCK mode.
    pub fn open_socket_tcp(self: *IO, blocking: bool) IOError!socket_t {
        // AF.INET means we're using an IPv4 Internet protocols
        const socket = try self.open_socket(c.AF.INET, c.SOCK.STREAM, c.IPPROTO.TCP, blocking);

        return socket;
    }

    /// Opens a socket given the domain and socket type.
    /// Always opens with `NONBLOCK`
    fn open_socket(self: *IO, domain: u32, socket_type: u32, protocol: u32, blocking: bool) IOError!socket_t {
        const socket = c.socket(domain, socket_type, protocol);

        if (socket < 0) {
            return switch (std.c.errno(socket)) {
                .ACCES => IOError.PermissionDenied,
                // Lumping these together for now, will see if separate errors make sense for these.
                .AFNOSUPPORT, .PROTONOSUPPORT, .PROTOTYPE => IOError.ProtocolNotSupported,
                .MFILE => IOError.ProcessFdLimitExceeded,
                .NFILE => IOError.SystemFdLimitExceeded,
                .NOBUFS, .NOMEM => IOError.InsufficientSystemResources,
                // According to man the above errors are the only possible ones.
                else => unreachable,
            };
        }
        errdefer self.close_socket(socket);

        // For async-io we need the socket to be non-blocking.
        if (!blocking) {
            try set_nonblock(socket);
        }

        return socket;
    }

    pub fn close_socket(self: *IO, socket: socket_t) void {
        _ = self;
        // Fire and forget for now, I don't know if it's possible to handle these errors? From what
        // I see over the internet this seems like a safe bet.
        _ = c.close(socket);
    }

    // The actual backlog is an i32 for some reason. The backlog length being negative doesn't make
    // much sense so I'm just going to prune it to take u31 and cast it at the call site.
    // According to the open standard providing a less than 0 value means that the system will take
    // some predefined/implementation defined max value which seems, just wrong.
    //
    // If you want to use the SOMAXCONN might as well give backlog as MAX_U31 since in case the
    // provided value is greater than the SOMAXCONN, then our value is discarded and it uses the
    // SOMAXCONN.
    pub fn listen(self: *IO, socket: socket_t, addr: [*:0]const u8, port: u16, backlog: u31) IOError!void {
        _ = self;

        // Quoting the Linux Programming Iterface book.
        // "REUSEADDR: to avoid the EADDRINUSE (“Address already in use”) error when a TCP server is
        // restarted and tries to bind a socket to a port that currently has an associated TCP."
        //
        // Essentially for paxos that I'm trying to achieve it would cut down the restart times
        // since without this the server would have to wait for the timeout during the restart to
        // bring up the same socket again.
        try setsockopt(socket, c.SOL.SOCKET, c.SO.REUSEADDR, 1);

        var addr_network_byte_order: u32 = undefined;
        const pton_res = inet_pton(c.AF.INET, addr, &addr_network_byte_order);
        // Returns only a single error called EAFNOTSUPPORT meaning the address is not supported.
        if (pton_res != 1) {
            return IOError.AddressNotLocal;
        }

        const address: c.sockaddr.in = .{
            // family and zero default to these values but we're just being safe.
            .family = c.AF.INET,
            .zero = @splat(0),
            .addr = addr_network_byte_order,
            .port = std.mem.nativeToBig(u16, port),
        };

        // All ports under 1024 are reserved and shouldn't be used, if you're dead set on using them
        // you need to be the super user. The program could check the port and shortcircuit early
        // but I don't think that's worth it. The function checks for everything no need to be the
        // superhero :p
        const bind_res = c.bind(socket, @ptrCast(&address), @sizeOf(c.sockaddr.in));

        // I really don't like this, but maybe this is why we've got abstractions so consumers don't
        // have to look at this.
        if (bind_res < 0) {
            return switch (c.errno(bind_res)) {
                .ACCES => IOError.PermissionDenied,
                .ADDRINUSE => IOError.AddressAlreadyInUse,
                .ADDRNOTAVAIL => IOError.AddressNotLocal,
                .AFNOSUPPORT => IOError.AddressFamilyMismatch,
                .BADF => IOError.SocketFileDescriptorInvalid,
                .DESTADDRREQ => IOError.AddressIsNull,
                .FAULT => IOError.AddressNotAccessible,
                .INVAL => IOError.SocketAlreadyBound,
                .NOTSOCK => IOError.NotASocket,
                .OPNOTSUPP => IOError.OperationNotSupported,
                // According to mac's man page these are UNIX only kept just in case.
                .LOOP => IOError.AddressLoopBack,
                .NAMETOOLONG => IOError.AddressTooLong,
                .NOENT => IOError.AddressNotFound,
                .NOTDIR => IOError.AddressNotDirectory,
                .ROFS => IOError.AddressReadOnly,
                else => unreachable,
            };
        }

        const listen_res = c.listen(socket, backlog);
        if (listen_res < 0) {
            return switch (c.errno(listen_res)) {
                .ACCES => IOError.PermissionDenied,
                .BADF => IOError.SocketFileDescriptorInvalid,
                .DESTADDRREQ => IOError.SocketNotBound,
                .INVAL => IOError.SocketAlreadyConnected,
                .NOTSOCK => IOError.NotASocket,
                .OPNOTSUPP => IOError.OperationNotSupported,
                else => unreachable,
            };
        }
    }

    fn connect(self: *IO, socket: socket_t, addr: [*:0]const u8, port: u16) IOError!void {
        _ = self;

        var addr_network_byte_order: u32 = undefined;
        const pton_res = inet_pton(c.AF.INET, addr, &addr_network_byte_order);
        if (pton_res != 1) {
            return IOError.AddressNotLocal;
        }

        const address: c.sockaddr.in = .{
            .family = c.AF.INET,
            .zero = @splat(0),
            .addr = addr_network_byte_order,
            .port = std.mem.nativeToBig(u16, port),
        };

        const connect_res = c.connect(socket, @ptrCast(&address), @sizeOf(@TypeOf(address)));
        if (connect_res < 0) {
            return switch (c.errno(connect_res)) {
                .ACCES => IOError.PermissionDenied,
                .ADDRINUSE => IOError.AddressAlreadyInUse,
                .ADDRNOTAVAIL => IOError.AddressNotAvailable,
                .AFNOSUPPORT => IOError.AddressFamilyMismatch,
                .ALREADY => IOError.ConnectionAlreadyInProgress,
                .BADF => IOError.SocketFileDescriptorInvalid,
                .CONNREFUSED => IOError.ConnectionRefused,
                .FAULT => IOError.AddressNotAccessible,
                .HOSTUNREACH => IOError.HostUnreachable,
                .INPROGRESS => IOError.ConnectionInProgress,
                .INTR => IOError.InterruptedBySignal,
                .INVAL => IOError.InvalidArgument,
                .ISCONN => IOError.SocketAlreadyConnected,
                .NETDOWN => IOError.NetworkDown,
                .NETUNREACH => IOError.NetworkUnreachable,
                .NOBUFS => IOError.InsufficientSystemResources,
                .NOTSOCK => IOError.NotASocket,
                .OPNOTSUPP => IOError.OperationNotSupported,
                .PROTOTYPE => IOError.AddressTypeMismatch,
                .TIMEDOUT => IOError.ConnectionTimedOut,
                .CONNRESET => IOError.ConnectionResetByPeer,
                // UNIX domain ones
                .IO => IOError.FileSystemIoError,
                .LOOP => IOError.AddressLoopBack,
                .NAMETOOLONG => IOError.AddressTooLong,
                .NOENT => IOError.NamedSocketNotFound,
                .NOTDIR => IOError.NotADirectory,
                else => unreachable,
            };
        }
    }

    /// Returns the dedicated socket for that connection. That socket would then be used to read and
    /// write for that TCP connecton.
    pub fn accept(self: *IO, listen_socket: socket_t, peer: *c.sockaddr.in, blocking: bool) IOError!socket_t {
        var len: c.socklen_t = @sizeOf(@TypeOf(peer.*));
        // Write the peer's info the the peer, and writes how many bytes it wrote to peer in the len
        // field.
        const new_socket = c.accept(listen_socket, @ptrCast(peer), &len);
        if (new_socket < 0) {
            return switch (c.errno(new_socket)) {
                .BADF => IOError.SocketFileDescriptorInvalid,
                .CONNABORTED => IOError.ConnectionAborted,
                .FAULT => IOError.AddressNotAccessible,
                .INTR => IOError.InterruptedBySignal,
                .INVAL => IOError.SocketNotListening,
                .MFILE => IOError.ProcessFdLimitExceeded,
                .NFILE => IOError.SystemFdLimitExceeded,
                .NOMEM => IOError.InsufficientSystemResources,
                .NOTSOCK => IOError.NotASocket,
                .OPNOTSUPP => IOError.OperationNotSupported,
                .AGAIN => IOError.WouldBlock,
                else => unreachable,
            };
        }
        errdefer self.close_socket(new_socket);

        if (!blocking) {
            try set_nonblock(new_socket);
        }

        return new_socket;
    }

    // Once again we're using u31 because send returns a signed int and well negative numbers are
    // errors so the effective range of bytes written to is u31.
    /// Returns the number of bytes written/sent and returns an IOError in case of an error.
    fn send(self: *IO, socket: socket_t, message: []const u8, flags: u32) IOError!u31 {
        _ = self;

        // Flags being
        //      MSG_OOB: Process out of band data
        //      MSG_DONTROUTE: Bypass routing, use direct interface.
        // None of which are required for us, so most of the time we'll be sending 0.
        //
        // For tcp `send` can send only some of the data, so keep an eye out for that.
        const send_res = c.send(socket, message.ptr, message.len, flags);
        if (send_res < 0) {
            return switch (c.errno(send_res)) {
                .ACCES => IOError.PermissionDenied,
                .ADDRNOTAVAIL => IOError.AddressNotAvailable,
                .AGAIN => IOError.WouldBlock,
                .BADF => IOError.SocketFileDescriptorInvalid,
                .CONNRESET => IOError.ConnectionResetByPeer,
                .DESTADDRREQ => IOError.AddressIsNull,
                .FAULT => IOError.AddressNotAccessible,
                .HOSTUNREACH => IOError.HostUnreachable,
                .INTR => IOError.InterruptedBySignal,
                .MSGSIZE => IOError.MessageTooLarge,
                .NETDOWN => IOError.NetworkDown,
                .NETUNREACH => IOError.NetworkUnreachable,
                .NOBUFS => IOError.InsufficientSystemResources,
                .NOTCONN => IOError.SocketNotConnected,
                .NOTSOCK => IOError.NotASocket,
                .OPNOTSUPP => IOError.OperationNotSupported,
                .PIPE => IOError.BrokenPipe,
                else => unreachable,
            };
        }
        return @as(u31, @intCast(send_res));
    }

    /// Returns the number of bytes read.
    fn recv(self: *IO, socket: socket_t, buffer: []u8, flags: u32) IOError!u31 {
        _ = self;

        const recv_res = c.recv(socket, buffer.ptr, buffer.len, @as(c_int, @intCast(flags)));
        if (recv_res < 0) {
            return switch (c.errno(recv_res)) {
                .AGAIN => IOError.WouldBlock,
                .BADF => IOError.SocketFileDescriptorInvalid,
                .CONNRESET => IOError.ConnectionResetByPeer,
                .FAULT => IOError.AddressNotAccessible,
                .INTR => IOError.InterruptedBySignal,
                .INVAL => IOError.InvalidArgument,
                .NOBUFS => IOError.InsufficientSystemResources,
                .NOTCONN => IOError.SocketNotConnected,
                .NOTSOCK => IOError.NotASocket,
                .OPNOTSUPP => IOError.OperationNotSupported,
                .TIMEDOUT => IOError.ConnectionTimedOut,
                else => unreachable,
            };
        }
        return @as(u31, @intCast(recv_res));
    }

    fn set_nonblock(socket: socket_t) IOError!void {
        const get_res = c.fcntl(socket, c.F.GETFL, @as(c_int, 0));
        if (get_res < 0) {
            return switch (c.errno(get_res)) {
                .BADF => IOError.SocketFileDescriptorInvalid,
                else => unreachable,
            };
        }

        var flags: c.O = @bitCast(get_res);
        flags.NONBLOCK = true;

        const set_res = c.fcntl(socket, c.F.SETFL, @as(c_int, @bitCast(flags)));
        if (set_res < 0) {
            return switch (c.errno(set_res)) {
                .BADF => IOError.SocketFileDescriptorInvalid,
                else => unreachable,
            };
        }
    }

    fn setsockopt(socket: socket_t, level: i32, option: u32, value: c_int) IOError!void {
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
                .BADF => IOError.SocketFileDescriptorInvalid,
                .DOM => IOError.OptionValueOutOfBounds,
                .FAULT => IOError.AddressNotAccessible,
                .INVAL => IOError.InvalidArgument,
                .ISCONN => IOError.SocketAlreadyConnected,
                .NOMEM, .NOBUFS => IOError.InsufficientSystemResources,
                .NOPROTOOPT => IOError.NotSupported,
                .NOTSOCK => IOError.NotASocket,
                else => unreachable,
            };
        }
    }
};

// Yeah, yeah I know, file named event_loop_async_io and we got a network that is blocking. One step
// at a time.
pub fn main(init: std.process.Init) !void {
    // Args parsing is a pain. I'll just have hardcoded stuff for now.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const server = if (std.mem.eql(u8, args[1], "server")) true else false;

    if (server) {
        var io: IO = .{};

        const socket = try io.open_socket_tcp(true);
        try io.listen(socket, "127.0.0.1", 3000, 128);

        var peer: c.sockaddr.in = undefined;
        const peer_conn_socket = try io.accept(socket, &peer, true);

        var buffer: [1024]u8 = undefined;
        while (true) {
            const bytes_received = try io.recv(peer_conn_socket, &buffer, 0);
            _ = try io.send(peer_conn_socket, "Nackxos!!! You there? Heh, you better be there", 0);

            // For TCP it means that the peer has closed his half-side of the connection. I forgot
            // to add this and it spun on till eternity.
            if (bytes_received == 0) break;
            std.debug.print("recv {d} bytes: {s}\n", .{ bytes_received, buffer[0..bytes_received] });
        }
    } else {
        var io: IO = .{};
        const socket = try io.open_socket_tcp(true);

        // Interesting fact: The connect takes care of the handshake, accept only drives whether the
        // connection is consumed by the listener. The connection is open at this point.
        try io.connect(socket, "127.0.0.1", 3000);
        // My humor is truly broken, don't judge me!!!
        _ = try io.send(socket, "Pack Sauce (Very bad word play on Paxos)!", 0);

        var buffer: [1024]u8 = undefined;
        const bytes_received = try io.recv(socket, &buffer, 0);
        std.debug.print("recv {d} bytes: {s}\n", .{ bytes_received, buffer[0..bytes_received] });

        io.close_socket(socket);
    }
}
