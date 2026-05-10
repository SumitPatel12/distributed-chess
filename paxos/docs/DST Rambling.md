# So You Want A DST Harness? (In An Archaic Voice: Welcome To The Jungle)
First things first event loops are everywhere and you need to understand them if you ever want to understand DST systems. We're talking about event loop for asynchronous I/O not the JS one (heh, I do JS for my day job, so I just took a joke at myself) [[el][]]

## So What Actually Do We Even Mean By Determinism And Non-Determinism In This Context?
Let's first define what we want our of our DST: ***"Given the same seed we want all of the events of our system to be identical"***. (At least that's what I think, and the rest of this section is based off of that assumption.)

With that in mind what would we define as non-deterministic in this context? Naturally anything that would lead to a different output given the same initial seed.

Now we'll look at the most common culprits that lead to such results:
- *RNG*: Directly using some kind of RNG in your core logic. It's RNG need I say more?
- *Clock times*: Clocks represent time and well it's absolute for us, but for computers the clocks drift, the NTP might be unavailable leading to major drifts, and many more. Between two runs you simply cannot guarantee that the clocks will yiedl the same output.
- *Concurrency*: We're at the mercy of the OS scheduler, it may pick one or the other and we can't guarantee which it will pick, given multiple of the same runs the OS is free to choose and hence the non-determinism. **This is also why we make it so that our system is capable of running on a single thread.**
- *Network*: If you know TCP then you know network is not reilable, in the sense that it can drop and reorder packets, there can be partitions, and 100 different things. All of which are well out of our control.
- *Storage*: This one is trickier, storage is reliable most of the times but there are rare cases where bytes get corrupted, or the OS is deciding fsync times and then there is OS managed buffers and more. All of which do things their way, and once again we can't guarantee that two runs would yield the smae order of .
- These are all I can think of.

## What for the Actual Implementation?
- kqueue for async network I/O on mac. (I'm on a mac so that's what I'll be going for, no other OS support). I don't know anything about this!! 
- An interface for message bus.

## What Should I Have In The Paxos DST?
- Seed
  - Each node will likely get its own seed, if we give each the same then each would do the same thing which is less than ideal I would say.
- Some main loop that acts as a cluster owner and runs the simulation
  - So the global simulation driver. Will likley own the top level seed and own the network and message bus stubs?
- Some kind of message bus cause that's how events would be consumed. Maybe??
  - This will require a lot more thinking on my part.
- Network of course will need to be stubbed
  - It's gonna need some way of managing individual packets/messages, and also distinguis them for each link (maybe? there could be that the struct stores from and to). Maybe look over the TCP semantics a bit. [[tc][]] [[ts][]]
  - Handle each link that extends between the nodes, since each can talk to one another it'd be like a star topology thing? So the number of links can be counted beforehand? Via options?
  - packet_loss_prob
  - packet_replay_prob
  - path_maximum_capacity 
  - Since paxos want's to reach consensus for just one thing, the packet lost prob should be high to simulate longer runs, maybe some kind of max_time, after which we reduce that high packet loss?
- We'll need clock
- I/O to disk so the logs that the system keeps. And If I want to have the trace events for animation, then those will need to stay in memory as well, I think? 
  - We will not be adding any type of fault injection for this. Network would be difficult enough for the first pass, plus I don't think paxos even assumes storage failures. So, yeah, no I/O faults for storage.
- 

## Rambling Begins
It's pretty much trying to remove the sources of non-determinism from your core logic. That includes clock(this is the big one, I think), blocking i/o, network i/o, disk, and more (I'm not sure of others :/).

The implementation and design architecture as I'm reading it needs to be an event loop that can be run on a single thread. Single thread so the DST harness cna run it deterministically. Essentially a prng will drive all of the events in the system, and for the given prng seed, it will (hopefully) always give you the same result. So a deterministic run, given the seed and the code state, changing your code would make it so that the seed may or may not produce the same result. I think that was a given, cause if you find a bug and fix it you'd expect it pass for the same seed now, that's the whole idea behind it.

From what [nucleus][nu] said, it seems like backing storage and network also require you use some in memory structures for processing, that makes the run's order of magnitude faster. (At this point I imagine this is gonna take me months and months not weeks ['']/)

The network needs to be a pluggable interface. I honestly don't know much about networks, so that's something I'll have to look more into. Likely a bit of [TCP semantics][tc], packet behaviour, and reordering of packets (i.e. delays that could happen).

Realizing that the two layers are completely differnt, should've known that. For async/io on mac I'll hvae to check how it's done, cause thats required for the DST.

## Resources:
- [Asynchronous I/O and Event Loops][el]
- [TigerBeetle][tb]
- [Dropbox Nucleus][nu]
- [TCP Simple Ideas][tc]
- [12 TCP State Transitions][ts]

[el]: https://mbinjamil.dev/writings/understanding-async-io/
[tb]: https://github.com/tigerbeetle/tigerbeetle
[nu]: https://dropbox.tech/infrastructure/-testing-our-new-sync-engine
[tc]: https://youtu.be/JFch3ctY6nE?si=tSX7p1iUEwYYOqYx
[ts]: https://youtu.be/CbEHpyeHhxM?si=zSu5TiIixA9yr8jm
