Each process will have the ability to act as a proposer and acceptor.
The processes/servers will discover themselves via network discovery. 
A single proposer will not send multiple prepares in parallel. The prepare and accept phases will be blocking with a sane timeout for each phase. Once that timeout runs out the method short-circuits, that way we don't wait for messages when they were dropped.

## Proposer
```
# Will have a main loop that will keep sending proposals until consensus is reached.

# The highest proposal number this machine has used thus far. Will be tracked in a log.
highest_proposed_number: u32,
const PREPARE_TIMEOUT: u32, // TIMEOUT IN MS
const ACCEPT_TIMEOUT: u32 // TIMEOUT IN MS

# The replayability logs and the essential logs will be kept in separate files.

# Will keep a log for replayability. Each propose_value request will log itself before running the function.
# Each branch of the prepare and accept will log it's own result:
	# If prepare fails due to timeout, we put a log
	# If prepare fials because majority rejected
	# If prepare fails because of timeout waiting for majority to agree
	# If prepare passes by majority accepted log it
	# Log the value with which accept is called
# Same for accept:
	# Log for fail timeout
	# Log for fail, majority rejected
	# Log for majority accepted


# Will have the following methods:
  - propose_value(v): Blocking, will run the prepare and accept phases.
  - prepare(n): Send the prepare message to the acceptors.
  - accept(n, v): Send the accept message to the acceptors.
  - is_consensus_reached: Will poll all of the acceptors and check if consensus is reached, will stop if the system has reached consensus.
  
# Network Messages:
enum NetworkMessage {
	PrepareRequest: {
		proposal_number: u32,
	},
	AcceptProposal: {
		proposal_number: u32,
		value: Value,
	},
	NackPrepare: {
		highest_promised_proposal_number: u32,
	},
	NackAcceptProposal {
		highest_promised_proposal_number: u32,
	}
}
```

## Acceptor
```
# Will have two methods:
	- acknowlege_prepare(n): The method to handle the prepare request.
	- accept_proposal(proposal): Accept the proposal

# Will keep track of the highest accepted proposal.
# Will keep track of the highest promised proposal number.

# The replayability logs and the essential logs will be kept in separate files.
# Will log events for replayability.
# For acknowledge_prepare:
	# Log if rejected due to prior promise
	# Log if promised
# For accept_proposal:
	# Log if rejected due to prior proimse
	# Log if accepted

# The log entries will look like: 
enum LogEntry {
	accepted_proposal: {
		proposal_number: u32,
		value: Value	
	},
	highest_acked_proposal_number: u32,
}
# The log entry will be put into a file named log.txt? I'm not sure what the convention is for these log files, so txt it is for now. It will be pu in the same directory from where the process is run. The name of the file is TBD.

```

## Learner
TODO