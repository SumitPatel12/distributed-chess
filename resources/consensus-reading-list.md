# Consensus Reading List

This list is split by learning stage, with a bias toward Paxos, Raft, implementation details, and intuitive explanations over heavy formalism.

## Beginner

These are the best starting points if you want to build intuition first and avoid getting buried in theory too early.

1. Raft paper: *In Search of an Understandable Consensus Algorithm*
   https://raft.github.io/raft.pdf

   Why read it:
   Best first paper for understanding consensus as a replicated log, leader election, and commit flow.

2. Raft home page
   https://raft.github.io/

   Why read it:
   Good hub for the paper, dissertation, talks, and related reference material.

3. The Morning Paper: *Paxos Made Simple*
   https://blog.acolyer.org/2015/03/04/paxos-made-simple/

   Why read it:
   A much easier on-ramp to Paxos before reading Lamport directly.

4. MIT Paxos lecture notes
   https://ocw.mit.edu/courses/6-824-distributed-computer-systems-engineering-spring-2006/resources/lec14_paxos/

   Why read it:
   Short, practical lecture notes that make the mechanics easier to follow.

5. Viewstamped Replication Revisited - The Morning Paper
   https://blog.acolyer.org/2015/03/06/viewstamped-replication-revisited/

   Why read it:
   Helpful if you want another intuitive explanation of consensus-style replication that is often easier to digest than Paxos.

## Intermediate

These are the canonical and more serious reads once the basic mental model is in place.

1. Leslie Lamport: *Paxos Made Simple*
   https://www.microsoft.com/en-us/research/publication/paxos-made-simple/

   Why read it:
   The standard concise explanation of basic Paxos.

2. Leslie Lamport: *The Part-Time Parliament*
   https://lamport.azurewebsites.net/pubs/lamport-paxos.pdf

   Why read it:
   The original Paxos paper. Important historically and conceptually, but definitely harder to read.

3. Diego Ongaro's dissertation
   https://raft.github.io/

   Why read it:
   A deeper treatment of Raft, including membership changes and more of the engineering story.

4. Barbara Liskov and James Cowling: *Viewstamped Replication Revisited*
   https://repository.aust.edu.ng/xmlui/handle/1721.1/71763

   Why read it:
   One of the clearest primary-source papers on replicated state machines and failover behavior.

5. FLP impossibility paper
   https://groups.csail.mit.edu/tds/papers/Lynch/jacm85.pdf

   Why read it:
   Foundational theory. Not implementation-focused, but it explains why consensus protocols look the way they do.

## Implementation Heavy

These are the most useful if you want to understand how consensus behaves in real systems and what code or engineering decisions matter.

1. Google: *Paxos Made Live - An Engineering Perspective*
   https://research.google/pubs/pub33002/

   Why read it:
   Probably the single best resource on the gap between Paxos-on-paper and Paxos-in-production.

2. Google Chubby paper
   https://www.usenix.org/event/osdi06/tech/full_papers/burrows/burrows_html/index.html

   Why read it:
   Shows how a real system used Paxos behind a higher-level service boundary instead of exposing raw consensus to every user.

3. MIT 6.5840 Raft lab
   https://pdos.csail.mit.edu/6.824/labs/lab-raft1.html

   Why read it:
   Excellent guided implementation path. One of the best ways to make consensus feel concrete.

4. MIT 6.824 Paxos lab
   https://pdos.csail.mit.edu/archive/6.824-2012/labs/lab-6.html

   Why read it:
   A practical path to implementing Paxos with real failure-handling concerns.

5. MIT 6.824 Paxos-based key/value service lab
   https://css.csail.mit.edu/6.824/2014/labs/lab-3.html

   Why read it:
   Helps connect Paxos itself to replicated state machine design and a real service API.

6. etcd/raft
   https://github.com/etcd-io/raft

   Why read it:
   Production-grade Raft library with a clean separation between the core algorithm and storage/network layers.

7. Go package docs for etcd/raft
   https://pkg.go.dev/go.etcd.io/etcd/raft

   Why read it:
   Good overview of practical extensions like read index, membership changes, and leadership transfer.

## Suggested Order

If you want a smooth path through the material:

1. Start with the Raft paper.
2. Read the Morning Paper summary of Paxos.
3. Read *Paxos Made Simple*.
4. Read *Paxos Made Live*.
5. Implement either the MIT Raft lab or MIT Paxos lab.
6. Study `etcd/raft` after you already understand the algorithmic model.
