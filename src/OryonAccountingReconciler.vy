# pragma version ^0.4.3

MAX_ASSETS: constant(uint256) = 16
MAX_ACCOUNTS: constant(uint256) = 64

interface IPool:
    def asset_count() -> uint256: view
    def asset_at(index: uint256) -> address: view
    def market_snapshot(asset: address) -> (uint256, uint256, uint256, uint256, uint256, uint256): view
    def debt_of(account: address, asset: address) -> uint256: view
    def collateral_balance(account: address, asset: address) -> uint256: view

struct AccountCheckpoint:
    debt_amount: uint256
    collateral_amount: uint256
    updated_at: uint256
    observed: bool

struct MarketCheckpoint:
    cash: uint256
    total_supply: uint256
    total_borrows: uint256
    total_reserves: uint256
    borrow_index: uint256
    supply_index: uint256
    updated_at: uint256
    observed: bool

event KeeperSet:
    keeper: indexed(address)
    allowed: bool

event AccountTracked:
    account: indexed(address)
    tracked: bool

event CheckpointWritten:
    asset: indexed(address)
    account: indexed(address)
    debt_amount: uint256
    collateral_amount: uint256

owner: public(address)
pool: public(address)
keepers: public(HashMap[address, bool])
accounts: DynArray[address, MAX_ACCOUNTS]
account_seen: HashMap[address, bool]
market_checkpoints: public(HashMap[address, MarketCheckpoint])
account_checkpoints: public(HashMap[address, HashMap[address, AccountCheckpoint]])

@deploy
def __init__(_pool: address):
    assert _pool != empty(address), "pool"
    self.owner = msg.sender
    self.pool = _pool
    self.keepers[msg.sender] = True

@internal
@view
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
@view
def _only_keeper():
    assert self.keepers[msg.sender], "keeper"

@internal
@view
def _asset_count() -> uint256:
    count: uint256 = staticcall IPool(self.pool).asset_count()
    if count > MAX_ASSETS:
        return MAX_ASSETS
    return count

@external
def transfer_ownership(new_owner: address):
    self._only_owner()
    assert new_owner != empty(address), "owner"
    self.owner = new_owner

@external
def set_pool(new_pool: address):
    self._only_owner()
    assert new_pool != empty(address), "pool"
    self.pool = new_pool

@external
def set_keeper(keeper: address, allowed: bool):
    self._only_owner()
    assert keeper != empty(address), "keeper"
    self.keepers[keeper] = allowed
    log KeeperSet(keeper=keeper, allowed=allowed)

@external
def track_account(account: address):
    self._only_keeper()
    assert account != empty(address), "account"
    if not self.account_seen[account]:
        assert len(self.accounts) < MAX_ACCOUNTS, "accounts"
        self.account_seen[account] = True
        self.accounts.append(account)
    log AccountTracked(account=account, tracked=True)

@external
def write_market_checkpoint(asset: address):
    self._only_keeper()
    cash: uint256 = 0
    total_supply: uint256 = 0
    total_borrows: uint256 = 0
    total_reserves: uint256 = 0
    borrow_index: uint256 = 0
    supply_index: uint256 = 0
    cash, total_supply, total_borrows, total_reserves, borrow_index, supply_index = staticcall IPool(self.pool).market_snapshot(asset)
    self.market_checkpoints[asset] = MarketCheckpoint(
        cash=cash,
        total_supply=total_supply,
        total_borrows=total_borrows,
        total_reserves=total_reserves,
        borrow_index=borrow_index,
        supply_index=supply_index,
        updated_at=block.timestamp,
        observed=True
    )

@external
def write_account_checkpoint(account: address, asset: address):
    self._only_keeper()
    debt_amount: uint256 = staticcall IPool(self.pool).debt_of(account, asset)
    collateral_amount: uint256 = staticcall IPool(self.pool).collateral_balance(account, asset)
    self.account_checkpoints[account][asset] = AccountCheckpoint(
        debt_amount=debt_amount,
        collateral_amount=collateral_amount,
        updated_at=block.timestamp,
        observed=True
    )
    log CheckpointWritten(asset=asset, account=account, debt_amount=debt_amount, collateral_amount=collateral_amount)

@external
def write_full_account(account: address):
    self._only_keeper()
    assert account != empty(address), "account"
    if not self.account_seen[account]:
        assert len(self.accounts) < MAX_ACCOUNTS, "accounts"
        self.account_seen[account] = True
        self.accounts.append(account)
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        asset: address = staticcall IPool(self.pool).asset_at(i)
        debt_amount: uint256 = staticcall IPool(self.pool).debt_of(account, asset)
        collateral_amount: uint256 = staticcall IPool(self.pool).collateral_balance(account, asset)
        self.account_checkpoints[account][asset] = AccountCheckpoint(
            debt_amount=debt_amount,
            collateral_amount=collateral_amount,
            updated_at=block.timestamp,
            observed=True
        )
        log CheckpointWritten(asset=asset, account=account, debt_amount=debt_amount, collateral_amount=collateral_amount)

@external
def write_all_markets():
    self._only_keeper()
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        asset: address = staticcall IPool(self.pool).asset_at(i)
        cash: uint256 = 0
        total_supply: uint256 = 0
        total_borrows: uint256 = 0
        total_reserves: uint256 = 0
        borrow_index: uint256 = 0
        supply_index: uint256 = 0
        cash, total_supply, total_borrows, total_reserves, borrow_index, supply_index = staticcall IPool(self.pool).market_snapshot(asset)
        self.market_checkpoints[asset] = MarketCheckpoint(
            cash=cash,
            total_supply=total_supply,
            total_borrows=total_borrows,
            total_reserves=total_reserves,
            borrow_index=borrow_index,
            supply_index=supply_index,
            updated_at=block.timestamp,
            observed=True
        )

@external
@view
def account_count() -> uint256:
    return len(self.accounts)

@external
@view
def account_at(index: uint256) -> address:
    assert index < len(self.accounts), "index"
    return self.accounts[index]

@external
@view
def observed_debt_sum(asset: address) -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_ACCOUNTS):
        if i >= len(self.accounts):
            break
        account: address = self.accounts[i]
        total += self.account_checkpoints[account][asset].debt_amount
    return total

@external
@view
def observed_collateral_sum(asset: address) -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_ACCOUNTS):
        if i >= len(self.accounts):
            break
        account: address = self.accounts[i]
        total += self.account_checkpoints[account][asset].collateral_amount
    return total

@external
@view
def market_debt_delta(asset: address) -> int256:
    return self._market_debt_delta(asset)

@internal
@view
def _market_debt_delta(asset: address) -> int256:
    market: MarketCheckpoint = self.market_checkpoints[asset]
    observed: uint256 = 0
    for i: uint256 in range(MAX_ACCOUNTS):
        if i >= len(self.accounts):
            break
        observed += self.account_checkpoints[self.accounts[i]][asset].debt_amount
    if market.total_borrows >= observed:
        return convert(market.total_borrows - observed, int256)
    return -convert(observed - market.total_borrows, int256)

@external
@view
def market_supply_delta(asset: address) -> int256:
    return self._market_supply_delta(asset)

@internal
@view
def _market_supply_delta(asset: address) -> int256:
    market: MarketCheckpoint = self.market_checkpoints[asset]
    observed: uint256 = 0
    for i: uint256 in range(MAX_ACCOUNTS):
        if i >= len(self.accounts):
            break
        observed += self.account_checkpoints[self.accounts[i]][asset].collateral_amount
    if market.total_supply >= observed:
        return convert(market.total_supply - observed, int256)
    return -convert(observed - market.total_supply, int256)

@external
@view
def checkpoint_age(asset: address) -> uint256:
    market: MarketCheckpoint = self.market_checkpoints[asset]
    if not market.observed:
        return max_value(uint256)
    if block.timestamp <= market.updated_at:
        return 0
    return block.timestamp - market.updated_at

@external
@view
def account_checkpoint_age(account: address, asset: address) -> uint256:
    checkpoint: AccountCheckpoint = self.account_checkpoints[account][asset]
    if not checkpoint.observed:
        return max_value(uint256)
    if block.timestamp <= checkpoint.updated_at:
        return 0
    return block.timestamp - checkpoint.updated_at

@external
@view
def stale_accounts(asset: address, max_age: uint256) -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_ACCOUNTS):
        if i >= len(self.accounts):
            break
        checkpoint: AccountCheckpoint = self.account_checkpoints[self.accounts[i]][asset]
        if not checkpoint.observed:
            total += 1
        elif block.timestamp > checkpoint.updated_at + max_age:
            total += 1
    return total

@external
@view
def reconciled(asset: address, tolerance: uint256) -> bool:
    debt_delta: int256 = self._market_debt_delta(asset)
    supply_delta: int256 = self._market_supply_delta(asset)
    if debt_delta < 0:
        debt_delta = -debt_delta
    if supply_delta < 0:
        supply_delta = -supply_delta
    return convert(debt_delta, uint256) <= tolerance and convert(supply_delta, uint256) <= tolerance
