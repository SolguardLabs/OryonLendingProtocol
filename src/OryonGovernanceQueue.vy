# pragma version ^0.4.3

MAX_PROPOSALS: constant(uint256) = 128

struct Proposal:
    target: address
    proposer: address
    asset: address
    action: bytes32
    value_a: uint256
    value_b: uint256
    value_c: uint256
    value_d: uint256
    eta: uint256
    expires_at: uint256
    approvals: uint256
    executed: bool
    canceled: bool

event ProposerSet:
    proposer: indexed(address)
    allowed: bool

event ProposalQueued:
    proposal_id: indexed(bytes32)
    target: indexed(address)
    asset: indexed(address)
    action: bytes32
    eta: uint256

event ProposalApproved:
    proposal_id: indexed(bytes32)
    approver: indexed(address)
    approvals: uint256

event ProposalClosed:
    proposal_id: indexed(bytes32)
    executed: bool
    canceled: bool

owner: public(address)
delay: public(uint256)
grace_period: public(uint256)
approval_threshold: public(uint256)
proposers: public(HashMap[address, bool])
approved_by: public(HashMap[bytes32, HashMap[address, bool]])
proposal_ids: DynArray[bytes32, MAX_PROPOSALS]
proposals: public(HashMap[bytes32, Proposal])

@deploy
def __init__(_delay: uint256, _grace_period: uint256, _approval_threshold: uint256):
    self.owner = msg.sender
    self.delay = _delay
    self.grace_period = _grace_period
    if _approval_threshold == 0:
        self.approval_threshold = 1
    else:
        self.approval_threshold = _approval_threshold
    self.proposers[msg.sender] = True

@internal
@view
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
@view
def _only_proposer():
    assert self.proposers[msg.sender], "proposer"

@external
def transfer_ownership(new_owner: address):
    self._only_owner()
    assert new_owner != empty(address), "owner"
    self.owner = new_owner

@external
def set_timing(new_delay: uint256, new_grace_period: uint256):
    self._only_owner()
    self.delay = new_delay
    self.grace_period = new_grace_period

@external
def set_approval_threshold(new_threshold: uint256):
    self._only_owner()
    assert new_threshold > 0, "threshold"
    self.approval_threshold = new_threshold

@external
def set_proposer(proposer: address, allowed: bool):
    self._only_owner()
    assert proposer != empty(address), "proposer"
    self.proposers[proposer] = allowed
    log ProposerSet(proposer=proposer, allowed=allowed)

@external
def queue(
    proposal_id: bytes32,
    target: address,
    asset: address,
    action: bytes32,
    value_a: uint256,
    value_b: uint256,
    value_c: uint256,
    value_d: uint256
):
    self._only_proposer()
    assert proposal_id != empty(bytes32), "proposal"
    assert target != empty(address), "target"
    assert action != empty(bytes32), "action"
    assert self.proposals[proposal_id].target == empty(address), "exists"
    assert len(self.proposal_ids) < MAX_PROPOSALS, "proposals"
    eta: uint256 = block.timestamp + self.delay
    self.proposals[proposal_id] = Proposal(
        target=target,
        proposer=msg.sender,
        asset=asset,
        action=action,
        value_a=value_a,
        value_b=value_b,
        value_c=value_c,
        value_d=value_d,
        eta=eta,
        expires_at=eta + self.grace_period,
        approvals=0,
        executed=False,
        canceled=False
    )
    self.proposal_ids.append(proposal_id)
    log ProposalQueued(proposal_id=proposal_id, target=target, asset=asset, action=action, eta=eta)

@external
def approve(proposal_id: bytes32):
    self._only_proposer()
    proposal: Proposal = self.proposals[proposal_id]
    assert proposal.target != empty(address), "proposal"
    assert not proposal.canceled and not proposal.executed, "closed"
    assert not self.approved_by[proposal_id][msg.sender], "approved"
    self.approved_by[proposal_id][msg.sender] = True
    self.proposals[proposal_id].approvals += 1
    log ProposalApproved(proposal_id=proposal_id, approver=msg.sender, approvals=self.proposals[proposal_id].approvals)

@external
def cancel(proposal_id: bytes32):
    proposal: Proposal = self.proposals[proposal_id]
    assert proposal.target != empty(address), "proposal"
    assert msg.sender == self.owner or msg.sender == proposal.proposer, "auth"
    assert not proposal.executed, "executed"
    self.proposals[proposal_id].canceled = True
    log ProposalClosed(proposal_id=proposal_id, executed=False, canceled=True)

@external
def mark_executed(proposal_id: bytes32):
    self._only_owner()
    assert self._is_ready(proposal_id), "ready"
    self.proposals[proposal_id].executed = True
    log ProposalClosed(proposal_id=proposal_id, executed=True, canceled=False)

@internal
@view
def _is_ready(proposal_id: bytes32) -> bool:
    proposal: Proposal = self.proposals[proposal_id]
    if proposal.target == empty(address):
        return False
    if proposal.canceled or proposal.executed:
        return False
    if proposal.approvals < self.approval_threshold:
        return False
    if block.timestamp < proposal.eta:
        return False
    if self.grace_period > 0 and block.timestamp > proposal.expires_at:
        return False
    return True

@external
@view
def is_ready(proposal_id: bytes32) -> bool:
    return self._is_ready(proposal_id)

@external
@view
def is_expired(proposal_id: bytes32) -> bool:
    proposal: Proposal = self.proposals[proposal_id]
    if proposal.target == empty(address) or proposal.executed:
        return False
    if self.grace_period == 0:
        return False
    return block.timestamp > proposal.expires_at

@external
@view
def proposal_count() -> uint256:
    return len(self.proposal_ids)

@external
@view
def proposal_at(index: uint256) -> bytes32:
    assert index < len(self.proposal_ids), "index"
    return self.proposal_ids[index]

@external
@view
def active_count() -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_PROPOSALS):
        if i >= len(self.proposal_ids):
            break
        proposal: Proposal = self.proposals[self.proposal_ids[i]]
        if proposal.target != empty(address) and not proposal.executed and not proposal.canceled:
            total += 1
    return total

@external
@view
def ready_count() -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_PROPOSALS):
        if i >= len(self.proposal_ids):
            break
        proposal_id: bytes32 = self.proposal_ids[i]
        proposal: Proposal = self.proposals[proposal_id]
        ready: bool = True
        if proposal.target == empty(address) or proposal.canceled or proposal.executed:
            ready = False
        if proposal.approvals < self.approval_threshold or block.timestamp < proposal.eta:
            ready = False
        if self.grace_period > 0 and block.timestamp > proposal.expires_at:
            ready = False
        if ready:
            total += 1
    return total
