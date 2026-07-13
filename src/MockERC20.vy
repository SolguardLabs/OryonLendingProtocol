# pragma version ^0.4.3

event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

name: public(String[64])
symbol: public(String[32])
decimals: public(uint8)
totalSupply: public(uint256)
minter: public(address)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

@deploy
def __init__(_name: String[64], _symbol: String[32], _decimals: uint8):
    self.name = _name
    self.symbol = _symbol
    self.decimals = _decimals
    self.minter = msg.sender

@internal
def _transfer(sender: address, receiver: address, amount: uint256):
    assert receiver != empty(address), "receiver"
    assert self.balanceOf[sender] >= amount, "balance"
    self.balanceOf[sender] -= amount
    self.balanceOf[receiver] += amount
    log Transfer(sender=sender, receiver=receiver, value=amount)

@external
def transfer(receiver: address, amount: uint256) -> bool:
    self._transfer(msg.sender, receiver, amount)
    return True

@external
def approve(spender: address, amount: uint256) -> bool:
    self.allowance[msg.sender][spender] = amount
    log Approval(owner=msg.sender, spender=spender, value=amount)
    return True

@external
def transferFrom(sender: address, receiver: address, amount: uint256) -> bool:
    allowed: uint256 = self.allowance[sender][msg.sender]
    if allowed != max_value(uint256):
        assert allowed >= amount, "allowance"
        self.allowance[sender][msg.sender] = allowed - amount
        log Approval(owner=sender, spender=msg.sender, value=allowed - amount)
    self._transfer(sender, receiver, amount)
    return True

@external
def mint(receiver: address, amount: uint256):
    assert msg.sender == self.minter, "minter"
    assert receiver != empty(address), "receiver"
    self.totalSupply += amount
    self.balanceOf[receiver] += amount
    log Transfer(sender=empty(address), receiver=receiver, value=amount)

@external
def burn(owner: address, amount: uint256):
    assert msg.sender == self.minter, "minter"
    assert self.balanceOf[owner] >= amount, "balance"
    self.balanceOf[owner] -= amount
    self.totalSupply -= amount
    log Transfer(sender=owner, receiver=empty(address), value=amount)

@external
def set_minter(new_minter: address):
    assert msg.sender == self.minter, "minter"
    assert new_minter != empty(address), "minter"
    self.minter = new_minter
