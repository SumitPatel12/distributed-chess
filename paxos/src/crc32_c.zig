const std = @import("std");
// This is a reflected value of the generator polynomial. The original would be: 0x1EDC6F41
const polynomial: u32 = 0x82F63B78;

// The code looks fucking simple, but the math behind it had me on my ropes end for frigging days.
// And I still don't get all of it. [-_-]
pub fn crc32c(buffer: []const u8) u32 {
    // For correct implementations we take a non-zero remainder cause if we're using a variable
    // length scheme, then if we choose the remainder to be 0, the algorithm will not detect added
    // or dropped leading zeroes.
    //
    // Ours won't suffer from this since it's a fixed size thing, but we're gonig for the right
    // approach nonetheless.
    var crc: u32 = 0xFFFFFFFF;

    for (buffer) |byte| {
        crc ^= byte;

        // We're going from left to right, and popping from right, meaning we're still doing the
        // reflection, just not reflecting the whole message. The reflection is implict.
        // I still don't firgging get this one.
        for (0..8) |_| {
            if (crc & 0x00000001 == 1) {
                crc = (crc >> 1) ^ polynomial;
            } else crc >>= 1;
        }
    }

    // XORing with all 1s prevents a false positive in the case where all of the bits in the message
    // were set to 0. If we followed our normal convention, all 0s would yield a 0 checksum which
    // the algorithm would deem correct.
    return crc ^ 0xFFFFFFFF;
}
