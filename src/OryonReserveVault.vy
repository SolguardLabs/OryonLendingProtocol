# pragma version ^0.4.3

MAX_ASSETS: constant(uint256) = 32
MAX_CONTROLLERS: constant(uint256) = 16

interface IERC20:
    def transfer(receiver: address, amount: uint256) -> bool: nonpayable
    def transferFrom(sender: address, receiver: address, amount: uint256) -> bool: nonpayable
    def balanceOf(owner: address) -> uint256: view

struct ReserveAccount:
    accounted_balance: uint256
    reserved_budget: uint256
    paid_out: uint256
    last_deposit: uint256
    last_payment: uint256
    active: bool

struct SpendingPolicy:
    daily_limit: uint256
    epoch_paid: uint256
    epoch_start: uint256
    recipient: address
    enabled: bool

event ControllerSet:
    controller: indexed(address)
    allowed: bool

event ReserveDeposited:
    asset: indexed(address)
    sender: indexed(address)
    amount: uint256

event BudgetSet:
    asset: indexed(address)
    recipient: indexed(address)
    daily_limit: uint256

event ReservePaid:
    asset: indexed(address)
    recipient: indexed(address)
    amount: uint256

owner: public(address)
controllers: public(HashMap[address, bool])
controller_list: DynArray[address, MAX_CONTROLLERS]
asset_list: DynArray[address, MAX_ASSETS]
asset_seen: HashMap[address, bool]
accounts: public(HashMap[address, ReserveAccount])
policies: public(HashMap[address, SpendingPolicy])

@deploy
def __init__():
    self.owner = msg.sender
    self.controllers[msg.sender] = True
    self.controller_list.append(msg.sender)

@internal
@view
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
@view
def _only_controller():
    assert self.controllers[msg.sender], "controller"

@internal
def _touch_asset(asset: address):
    if not self.asset_seen[asset]:
        assert len(self.asset_list) < MAX_ASSETS, "assets"
        self.asset_seen[asset] = True
        self.asset_list.append(asset)
        self.accounts[asset].active = True

@internal
@pure
def _epoch(timestamp: uint256) -> uint256:
    return timestamp // 86_400

@external
def transfer_ownership(new_owner: address):
    self._only_owner()
    assert new_owner != empty(address), "owner"
    self.owner = new_owner

@external
def set_controller(controller: address, allowed: bool):
    self._only_owner()
    assert controller != empty(address), "controller"
    if allowed and not self.controllers[controller]:
        assert len(self.controller_list) < MAX_CONTROLLERS, "controllers"
        self.controller_list.append(controller)
    self.controllers[controller] = allowed
    log ControllerSet(controller=controller, allowed=allowed)

@external
def deposit(asset: address, amount: uint256):
    assert amount > 0, "amount"
    self._touch_asset(asset)
    ok: bool = extcall IERC20(asset).transferFrom(msg.sender, self, amount)
    assert ok, "transfer"
    self.accounts[asset].accounted_balance += amount
    self.accounts[asset].last_deposit = block.timestamp
    log ReserveDeposited(asset=asset, sender=msg.sender, amount=amount)

@external
def register_external_income(asset: address, amount: uint256):
    self._only_controller()
    assert amount > 0, "amount"
    self._touch_asset(asset)
    self.accounts[asset].accounted_balance += amount
    self.accounts[asset].last_deposit = block.timestamp
    log ReserveDeposited(asset=asset, sender=msg.sender, amount=amount)

@external
def set_budget(asset: address, recipient: address, daily_limit: uint256):
    self._only_owner()
    assert asset != empty(address), "asset"
    assert recipient != empty(address), "recipient"
    self._touch_asset(asset)
    self.policies[asset] = SpendingPolicy(
        daily_limit=daily_limit,
        epoch_paid=0,
        epoch_start=self._epoch(block.timestamp),
        recipient=recipient,
        enabled=True
    )
    log BudgetSet(asset=asset, recipient=recipient, daily_limit=daily_limit)

@external
def disable_budget(asset: address):
    self._only_owner()
    self.policies[asset].enabled = False

@external
def increase_reserved_budget(asset: address, amount: uint256):
    self._only_controller()
    self._touch_asset(asset)
    self.accounts[asset].reserved_budget += amount

@external
def reduce_reserved_budget(asset: address, amount: uint256):
    self._only_controller()
    current: uint256 = self.accounts[asset].reserved_budget
    if amount >= current:
        self.accounts[asset].reserved_budget = 0
    else:
        self.accounts[asset].reserved_budget = current - amount

@internal
def _refresh_epoch(asset: address):
    current_epoch: uint256 = self._epoch(block.timestamp)
    if self.policies[asset].epoch_start < current_epoch:
        self.policies[asset].epoch_start = current_epoch
        self.policies[asset].epoch_paid = 0

@external
def pay(asset: address, amount: uint256):
    self._only_controller()
    assert amount > 0, "amount"
    self._refresh_epoch(asset)
    policy: SpendingPolicy = self.policies[asset]
    assert policy.enabled, "policy"
    assert policy.recipient != empty(address), "recipient"
    assert self.accounts[asset].accounted_balance >= amount, "balance"
    if policy.daily_limit > 0:
        assert policy.epoch_paid + amount <= policy.daily_limit, "limit"
    self.accounts[asset].accounted_balance -= amount
    self.accounts[asset].paid_out += amount
    self.accounts[asset].last_payment = block.timestamp
    self.policies[asset].epoch_paid += amount
    ok: bool = extcall IERC20(asset).transfer(policy.recipient, amount)
    assert ok, "transfer"
    log ReservePaid(asset=asset, recipient=policy.recipient, amount=amount)

@external
def pay_to(asset: address, recipient: address, amount: uint256):
    self._only_owner()
    assert recipient != empty(address), "recipient"
    assert self.accounts[asset].accounted_balance >= amount, "balance"
    self.accounts[asset].accounted_balance -= amount
    self.accounts[asset].paid_out += amount
    self.accounts[asset].last_payment = block.timestamp
    ok: bool = extcall IERC20(asset).transfer(recipient, amount)
    assert ok, "transfer"
    log ReservePaid(asset=asset, recipient=recipient, amount=amount)

@external
@view
def controller_count() -> uint256:
    return len(self.controller_list)

@external
@view
def controller_at(index: uint256) -> address:
    assert index < len(self.controller_list), "index"
    return self.controller_list[index]

@external
@view
def asset_count() -> uint256:
    return len(self.asset_list)

@external
@view
def asset_at(index: uint256) -> address:
    assert index < len(self.asset_list), "index"
    return self.asset_list[index]

@external
@view
def available(asset: address) -> uint256:
    account: ReserveAccount = self.accounts[asset]
    if account.accounted_balance <= account.reserved_budget:
        return 0
    return account.accounted_balance - account.reserved_budget

@external
@view
def token_balance(asset: address) -> uint256:
    return staticcall IERC20(asset).balanceOf(self)

@external
@view
def is_reconciled(asset: address) -> bool:
    actual: uint256 = staticcall IERC20(asset).balanceOf(self)
    return actual >= self.accounts[asset].accounted_balance

@external
@view
def daily_remaining(asset: address) -> uint256:
    policy: SpendingPolicy = self.policies[asset]
    if not policy.enabled:
        return 0
    if policy.daily_limit == 0:
        return max_value(uint256)
    current_epoch: uint256 = self._epoch(block.timestamp)
    if current_epoch > policy.epoch_start:
        return policy.daily_limit
    if policy.epoch_paid >= policy.daily_limit:
        return 0
    return policy.daily_limit - policy.epoch_paid

@external
@view
def aggregate_accounted() -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_ASSETS):
        if i >= len(self.asset_list):
            break
        total += self.accounts[self.asset_list[i]].accounted_balance
    return total

@external
@view
def aggregate_reserved() -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_ASSETS):
        if i >= len(self.asset_list):
            break
        total += self.accounts[self.asset_list[i]].reserved_budget
    return total
