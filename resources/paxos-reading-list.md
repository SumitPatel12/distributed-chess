# Paxos Reading List

This list is intentionally narrower and more opinionated than a generic consensus list. The goal is not coverage for its own sake; it is to give you the strongest path to actually understanding Paxos, including where the original literature is elegant, where it is frustrating, and where implementation reality starts to matter more than the clean theory.

## Best First

If you only read a few things, read these in this order:

1. Leslie Lamport: *Paxos Made Simple*
   https://www.microsoft.com/en-us/research/publication/paxos-made-simple/

   Why it matters:
   This is still the canonical short explanation of basic Paxos.

2. Adrian Colyer: *Paxos Made Simple* summary
   https://blog.acolyer.org/2015/03/04/paxos-made-simple/

   Why it matters:
   Best lightweight companion if Lamport's paper feels denser than expected.

3. Robbert van Renesse: *Paxos Made Moderately Complex*
   https://www.cs.cornell.edu/home/rvr/Paxos/paxos.pdf

   Why it matters:
   This is one of the best bridges from single-decree Paxos to the practical shape people often mean when they say "Paxos" in systems work.

4. Google: *Paxos Made Live - An Engineering Perspective*
   https://research.google/pubs/pub33002/

   Why it matters:
   The best paper on the gap between the beautiful algorithm and the messy production system.

5. MIT 6.824 Lecture 5: Paxos
   https://people.csail.mit.edu/alinush/6.824-spring-2015/l05-paxos.html

   Why it matters:
   Great course-style explanation that connects Paxos to replicated state machines and the engineering mindset.

## Primary Sources

These are the most important primary references.

1. Leslie Lamport: *The Part-Time Parliament*
   https://lamport.azurewebsites.net/pubs/lamport-paxos.pdf

   What it gives you:
   The original Paxos paper. Historically essential, intellectually important, and harder to absorb than later explanations.

2. Leslie Lamport: *Paxos Made Simple*
   https://www.microsoft.com/en-us/research/publication/paxos-made-simple/

   What it gives you:
   The core algorithm stated much more directly than the original paper.

3. Leslie Lamport: *Fast Paxos*
   https://www.microsoft.com/en-us/research/publication/fast-paxos/

   What it gives you:
   A valuable advanced read once you understand classic Paxos and want to see how the design space opens up.

## Explanation-Focused Resources

These are the best resources when you want intuition and narrative, not just correctness arguments.

1. Adrian Colyer: *Paxos Made Simple*
   https://blog.acolyer.org/2015/03/04/paxos-made-simple/

2. MIT 6.824 Lecture 5: Paxos
   https://people.csail.mit.edu/alinush/6.824-spring-2015/l05-paxos.html

3. Robbert van Renesse: *Paxos Made Moderately Complex*
   https://www.cs.cornell.edu/home/rvr/Paxos/paxos.pdf

   Note:
   Even though this is more detailed than a blog post, it is one of the best explanatory documents because it does not stop at the toy form of Paxos.

## Implementation-Heavy Resources

These are the resources I would use if the goal is to implement Paxos or understand how real systems used it.

1. Google: *Paxos Made Live - An Engineering Perspective*
   https://research.google/pubs/pub33002/

   Why read it:
   Best implementation-oriented Paxos paper, full stop.

2. Mike Burrows: *The Chubby Lock Service for Loosely-Coupled Distributed Systems*
   https://www.usenix.org/legacy/event/osdi06/tech/full_papers/burrows/burrows_html/index.html

   Why read it:
   Shows how Google wrapped Paxos inside a real service boundary that application teams could actually use.

3. MIT 6.824 Lab 6: Paxos
   https://pdos.csail.mit.edu/archive/6.824-2012/labs/lab-6.html

   Why read it:
   A strong hands-on implementation path for agreement and view changes.

4. MIT 6.824 Lab 3: Paxos-based Key/Value Service
   https://css.csail.mit.edu/6.824/2014/labs/lab-3.html

   Why read it:
   Useful for seeing how Paxos turns into a replicated state machine rather than remaining an isolated protocol.

5. Robbert van Renesse: *Paxos Made Moderately Complex*
   https://www.cs.cornell.edu/home/rvr/Paxos/paxos.pdf

   Why read it:
   This is the strongest "I want enough detail to build the thing" text before you move into code.

## Suggested Learning Path

If your goal is deep understanding rather than quick familiarity:

1. Read *Paxos Made Simple*.
2. Read the Morning Paper summary immediately after it.
3. Read the MIT 6.824 Paxos lecture notes.
4. Read *Paxos Made Moderately Complex*.
5. Read *Paxos Made Live*.
6. Read the Chubby paper.
7. Implement the MIT Paxos lab.
8. Only then go back to *The Part-Time Parliament* if you want the full historical and conceptual foundation.

## Notes

- Paxos is often presented in a form that is easier to prove correct than to implement.
- A lot of practical systems discussion actually depends on Multi-Paxos style behavior, even when the phrase "Paxos" is used loosely.
- If a resource helps you understand only single-decree Paxos, it is necessary but not sufficient for system-building intuition.
