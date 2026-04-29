# Zobrist Hashing
Zobrist hashing is a way for us to represnt the current position of the board via a hash, generally a 64 bit number. The idea is simple if the result hash of two positions are same then we can conclude that the positions are same. This helps with the `threefold repetition` detection for draws, and for chess engines it helps save compute by not having to analyze the same position again.

The key idea is simple, before the game starts, an array of pseudo-random numbers are generated:
- One for each unique piece on each square. 12 unique pieces and 64 square. (12 * 64 = 768)
- One for each file of the en passant square. (8)
- One for each of the castling right (White kingside, White queenside, Black kingside, Black queenside = 4)
- One that represents which sides turn it is. (1)

Totaling to 768 + 8 + 4 + 1 = 781.

The hashig works by XORing the each piece's current square hash with the castling hash, and then xoring all valid castling rights, if it's white's turn XOR the side has as well, and finally if there are any active enpassant square we take the file has and XOR it.

Essentially an initial position hash would look something like this:
```
[Hash of White Rook on a1] XOR [Hash of White Knight on a2] XOR ... [Hash of Black Knight on f8] XOR [Hash of Black Rook on f8] XOR
[Hash of White Kingside castle] XOR [Hash of White Queenside castle] XOR [Hash of Black Kingside castle] XOR [Hash of Black Queenside castle] XOR
[Side Hash]
```

And now if you make a move say d2 -> d4, then you have two options:
1. Calculate the whole hash anew.
2. XOR with the pawn's hash at d2 then XOR with pawns hash at d4.
  3. This works because XOR is it's own inverse, XORing with itself negates, so we essentially negated that piece's last hash and added in the new one.
  
This is mostly useful if you're trying to create a chess engine which has to calculate thousands if not millions of positions in a single second. For normal chess games, you don't need to do this since the amound of time it takes to walk a board and calcualte the hash is in the nano-second to single digit micorseconds range (from my calculations and benchmakrs, it may differ for you, but it's still well out of the human cognition range), quite unnoticalbe for the scale at which humans are going to play over the board. 

To back that claim you can check what Lichess does here: [Lichess Hash Position](https://github.com/lichess-org/scalachess/blob/6ad67ba473ad5a6fa419c9109a7e54afabb888fa/core/src/main/scala/Hash.scala#L35)


## References
[Zobrist Hashing - Chess Programming](https://www.chessprogramming.org/Zobrist_Hashing)
[Polygot Values](https://python-chess.readthedocs.io/en/latest/_modules/chess/polyglot.html)
