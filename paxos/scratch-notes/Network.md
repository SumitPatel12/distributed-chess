The zig posix library has lost a lot of it's socket related functions in favor of the std lib it seems. Since I plan on learning the things, I'll be using the std.c to circumvent this and write my own wrappers.

## So What's the Flow You Ask?
You get a socket, bind it to the address, start listening, and then accept connection requests. To connect to the server you create a socket, and just pass the address you want to connect to, and after the peer socket accepts you're good to go. That's the very dumbed down version of things. There's a lot of nuance while creating these sockets like should it be blocking or non-blocking, what options should it have, timeouts and all the good (and the scary) stuff.

The interesting thing I found was:
- After a socket is created and it starts listening, to establish a connection i.e. for a TCP handshake to occur you don't need to accept first, any client that want's to connect with this socket can call the `connect` method with the right address and the kernel will take care of the TCP handshake, establish the connection, and queue it up in the accept buffer. When the server calls `accept` they only take the data from the aforementioned buffer, and open a dedicated fd for that connection, the connection was already established, we just said yeah, I'm ready to communicate with you now.
- Writes ofcourse don't happen atomically when you send data over the connection the protocol is free to send howermany bytes they want, so a 100 byte message can range from 1 to 100 packets. So, you have to have some **message scheme** that would let you distinguish message boundaries.
- Everything can fail in multiple ways and you should know which scenarios warrant a retry and which are not. E.g. `WouldBlock` and `Again` you should retry, connection closed, then it's probably a better idea to drop this and resend after the connection has been known to have been re-established.

## Blocking Mode
Most of the calls would block, i.e. accept would block until a connection request comes in, writes and reads would blcok, almost every other function would block, and that's particularly bad when you have a system that exchanges data infrequently. Your thread/process will be wistfully waiting for a read that the peer might never send, or vice versa (there are timeouts for that, but still). 
You can have threads to handle each individula connection but then the threads themselves will still block so you freed you main thread/process but you still put the runners to sleep?(I'm not a 100% confident of this, TODO: Double Check).

## Write and Read
For tcp these are not guaranteed to send the whole message in one iteration. The call actually returns how many bytes were read or written to. You can either write the I/O in a way that it would make sure that all of the bytes were written to, but for non-blocking ones you don't even know so, likely something for a layer above it. Either the callers responsibility or have a message bus that handles it.

Oh, and reads can end up reading a part of the next message as well, so you need some kind of **message format** so we can bifurcate between one message and the next. Likely it needs to encode the length of the message, checksums (if we want), if we've got a lot of message types then a byte or two to indicate what kind of message it is, so we can infer the structure. Then deserialize it likely from raw bytes to a pointer coerce.

A message bus makes sense for the non-blocking I/O because it can keep track of the current message parts of next messages read if any and the like, the greater part of the system would then interact with the message bus that would abstract out the granly details of managing state for the TCP messages. The big thing here is that the raw socket interfaces can error in a lot of different ways and we need to decide which ones result in retries and which ones are actual errors. Interesting things, specially when there a `SystemOutOfResources` error maybe try with some jittered timeout?

## Non Blocking Mode (I/O Uring and Kqueue)
**This is just something I think right now, might change down the line**
The more I think non-blocking the more an idea of a wrapper around the core I/O interface that would manage the outside interaction sound better. It can handle timouts, jitters, real vs retry errors, track message buffers, reads, writes, connections, handle torn connections internally, etc.
