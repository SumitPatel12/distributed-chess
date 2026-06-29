BTW CRC stands for Cyclic Redundancy Check. I doublt I'll remember it, but doesn't hurt to look it up.

It's a checksum alogrith, the author says it's generally appended at the end of the messge. I'm going to be appending it to the start of mine.

The algorith should:
- Have enought width that the probability for failure is close to zero. For exaple for a 32 bit register, it'd be 1/2^32 which is abyssmal.
- Each bit in the calcualtion of checksum should hold the potential to affect the final output.

Divison suffices where addition does not. A divisor ~(as wide as the register) would do the trick.

Basic idea, **Not the actual CRC algorithm**:
- Encode
  - Treat the data we want the checksum of as a byte sequence.
  - Divide the byte sequence (in it's binary form) by a binary number of appropriate width.
  - The remainder is the checksum.

- Decode
  - Once again treat data as binary stream in it's entirety.
  - Take the same number and perform the division on this stream.
  - Compare remainder with the original checksum that was transmitted.
    - if they are the same the data is thought to be clean otherwise it's corrupted.


----------
Damn he's talking about treating each byte or word as some polynomial meaning 00101001 => `x^5 + x^3 + 0*x^2 + 0*x + 1`. You get the gist of it. binary means bit\*2^(index) we take bit\*x^(index). One of the few times that the polynomial math I was taught in school is yielding returns. :laughing:

Not gonna lie I don't understand a lot of the document. Especially when he said, divisor, divident, quotient, and remainder are to be treated as polynomials.

He says the arethmetic is supposed to be performed as mod 2. Meaning the co-efficients of the polynomials are either 1 or 0. So, addition would ignore carries, 1 + 1 will be 0, 0 + 0 will be 0, 1 + 0 and 0 + 1 will be 1. (XOR?) Subratction is the same, undeflow case 0 - 1 is just a wraparound so it still yields 1. (Definitely going towards XOR). And yup N + 0 = N and N - 0 = N still holds here. Who woulda thought!?

The multiplication and division use the above mentioned addition and subtraction logic. Who the fuck came up with this maddness??? Hat's off to them though, I can't even wrap my head around the complete idea, and the man/woman just came up with this shit. Maybe one day I'll be half as competent as them if not fully as competent.

Hold on to your horses here guys, things are about to get ugly! Multiple in the CRC arethmetic (number N is a multiple of number K) iff N can be derived by XORing different shifted values of K. :exploding_head:. Well given the above statements that's self explanatory, but it goes against your natural instaince that you build over the better part of your life, so try to remember this at all times during this thing.

Width of the polynomial or we'll just look for the binary W is the position of the highest set bit. The position is calculated from right to left and start with a 0. E.g. `10011` has a widhth of ***4*** not 5. (Yeah, I know one more thing to challenge our everyday thinking).

To make the arethmetic work, a message that we want to encode is appended with W (width) zeroes, likely so that we know that the number is greater than our polynomial (this just a wild guess, don't hold me to it).

Quoted verbatim from the text:
A summary of the operation of the class of CRC algorithms:
1. Choose a width W, and a poly G (of width W).
2. Append W zero bits to the message. Call this M'.
3. Divide M' by G using CRC arithmetic. The remainder is the checksum.
That's all there is to it.

If only it were that simple to me. :melting_face:


Once again taken verbatim from the text: ***"This section merely aims to put the fear of death into anyone who so much as toys with the idea of making up their own poly"***. What a statement ['_']/

There's also fucking relfection and how that ties into the algorithm. I'm losing my mind here.
