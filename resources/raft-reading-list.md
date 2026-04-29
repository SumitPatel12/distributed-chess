# Raft Reading List

This list is tuned for learning Raft well, not just collecting links. Raft is easier to approach than Paxos, so the best path here is to move quickly from the paper to implementation-oriented material and then to production code.

## Best First

If you only read a few things, read these in this order:

1. Diego Ongaro and John Ousterhout: *In Search of an Understandable Consensus Algorithm* (extended version)
   https://raft.github.io/raft.pdf

   Why it matters:
   This is the core Raft paper and still the best first read.

2. Raft project page
   https://raft.github.io/

   Why it matters:
   Best central hub for the paper, talks, dissertation, and related materials.

3. MIT 6.824 Lecture 6: Raft
   https://people.csail.mit.edu/alinush/6.824-spring-2015/l06-raft.html

   Why it matters:
   Excellent companion explanation after the paper, especially if you want the systems angle.

4. The Secret Lives of Data: Raft
   https://thesecretlivesofdata.com/raft/

   Why it matters:
   Still one of the best intuition builders for leader election and log replication.

5. MIT 6.5840 Lab 3: Raft
   https://pdos.csail.mit.edu/6.824/labs/lab-raft1.html

   Why it matters:
   The fastest route from paper knowledge to actual understanding-through-implementation.

## Primary Sources

These are the most important primary references.

1. Diego Ongaro and John Ousterhout: *In Search of an Understandable Consensus Algorithm* (extended version)
   https://raft.github.io/raft.pdf

2. USENIX conference page for the Raft paper
   https://www.usenix.org/conference/atc14/technical-sessions/presentation/ongaro

   What it gives you:
   The conference publication page plus associated talk material.

3. Diego Ongaro: dissertation repository, *Consensus: Bridging Theory and Practice*
   https://github.com/ongardie/dissertation

   What it gives you:
   The deepest primary-source treatment of Raft, including membership changes, correctness, and implementation discussion.

## Explanation-Focused Resources

These are the best resources when you want Raft to click quickly.

1. Raft project page
   https://raft.github.io/

2. MIT 6.824 Lecture 6: Raft
   https://people.csail.mit.edu/alinush/6.824-spring-2015/l06-raft.html

3. The Secret Lives of Data: Raft
   https://thesecretlivesofdata.com/raft/

   Note:
   This is not a primary academic source, but it is unusually good as a teaching aid.

## Implementation-Heavy Resources

These are the resources I would use if the goal is to implement Raft or understand how a production Raft library is structured.

1. MIT 6.5840 Lab 3: Raft
   https://pdos.csail.mit.edu/6.824/labs/lab-raft1.html

   Why read it:
   Best guided implementation path for core Raft.

2. MIT 6.5840 Lab 4: Fault-tolerant Key/Value Service
   https://pdos.csail.mit.edu/6.824/labs/lab-kvraft1.html

   Why read it:
   This is where Raft stops being a protocol on paper and starts becoming a real replicated service.

3. `etcd/raft`
   https://github.com/etcd-io/raft

   Why read it:
   Probably the most important production-grade Raft codebase to study.

4. Go package docs for `etcd/raft`
   https://pkg.go.dev/go.etcd.io/etcd/raft

   Why read it:
   Good map of practical features like membership changes, read paths, and leadership transfer.

5. Diego Ongaro dissertation repository
   https://github.com/ongardie/dissertation

   Why read it:
   Best place to go once you want more than the paper gives you, especially around cluster membership and full-system concerns.

## Suggested Learning Path

If your goal is strong working understanding:

1. Read the Raft paper.
2. Use the MIT lecture notes to restate the model in your own words.
3. Use The Secret Lives of Data to solidify elections, terms, and log replication.
4. Implement MIT Lab 3.
5. Continue into MIT Lab 4 so Raft becomes part of a service, not just a protocol.
6. Study `etcd/raft`.
7. Read Ongaro's dissertation when you want the deeper and more complete picture.

## Notes

- Raft is often the better first consensus algorithm to implement, even if Paxos is the one you most want to respect historically.
- The best way to learn Raft is to move into implementation quickly; the paper is unusually complete compared with Paxos.
- `etcd/raft` is valuable because it shows a clean separation between the consensus core and transport/storage integration.
