# pragma version ^0.4.3

WAD: constant(uint256) = 10**18
MAX_ASSETS: constant(uint256) = 16

interface IPool:
    def asset_count() -> uint256: view
    def asset_at(index: uint256) -> address: view
    def market_snapshot(asset: address) -> (uint256, uint256, uint256, uint256, uint256, uint256): view
    def account_values(account: address) -> (uint256, uint256, uint256): view
    def health_factor(account: address) -> uint256: view
    def max_borrow_value(account: address) -> uint256: view
    def debt_of(account: address, asset: address) -> uint256: view
    def collateral_balance(account: address, asset: address) -> uint256: view
    def utilization(asset: address) -> uint256: view
    def borrow_rate(asset: address) -> uint256: view
    def preview_liquidation(borrower: address, debt_asset: address, collateral_asset: address, max_repay: uint256) -> (uint256, uint256): view

struct MarketRow:
    asset: address
    cash: uint256
    total_supply: uint256
    total_borrows: uint256
    total_reserves: uint256
    borrow_index: uint256
    supply_index: uint256
    utilization: uint256
    borrow_rate: uint256

struct AccountRow:
    asset: address
    collateral_amount: uint256
    debt_amount: uint256

struct AccountSummary:
    collateral_value: uint256
    debt_value: uint256
    liquidity_value: uint256
    health_factor: uint256
    max_borrow_value: uint256

owner: public(address)
pool: public(address)

@deploy
def __init__(_pool: address):
    assert _pool != empty(address), "pool"
    self.owner = msg.sender
    self.pool = _pool

@internal
@view
def _only_owner():
    assert msg.sender == self.owner, "owner"

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

@internal
@view
def _asset_count() -> uint256:
    count: uint256 = staticcall IPool(self.pool).asset_count()
    if count > MAX_ASSETS:
        return MAX_ASSETS
    return count

@internal
@view
def _asset_at(index: uint256) -> address:
    return staticcall IPool(self.pool).asset_at(index)

@internal
@view
def _market_row(asset: address) -> MarketRow:
    cash: uint256 = 0
    total_supply: uint256 = 0
    total_borrows: uint256 = 0
    total_reserves: uint256 = 0
    borrow_index: uint256 = 0
    supply_index: uint256 = 0
    cash, total_supply, total_borrows, total_reserves, borrow_index, supply_index = staticcall IPool(self.pool).market_snapshot(asset)
    util: uint256 = staticcall IPool(self.pool).utilization(asset)
    rate: uint256 = staticcall IPool(self.pool).borrow_rate(asset)
    return MarketRow(
        asset=asset,
        cash=cash,
        total_supply=total_supply,
        total_borrows=total_borrows,
        total_reserves=total_reserves,
        borrow_index=borrow_index,
        supply_index=supply_index,
        utilization=util,
        borrow_rate=rate
    )

@external
@view
def market_row(asset: address) -> MarketRow:
    return self._market_row(asset)

@external
@view
def market_row_at(index: uint256) -> MarketRow:
    assert index < self._asset_count(), "index"
    return self._market_row(self._asset_at(index))

@external
@view
def market_rows() -> DynArray[MarketRow, MAX_ASSETS]:
    rows: DynArray[MarketRow, MAX_ASSETS] = []
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        rows.append(self._market_row(self._asset_at(i)))
    return rows

@external
@view
def account_summary(account: address) -> AccountSummary:
    collateral_value: uint256 = 0
    debt_value: uint256 = 0
    liquidity_value: uint256 = 0
    collateral_value, debt_value, liquidity_value = staticcall IPool(self.pool).account_values(account)
    health: uint256 = staticcall IPool(self.pool).health_factor(account)
    max_borrow: uint256 = staticcall IPool(self.pool).max_borrow_value(account)
    return AccountSummary(
        collateral_value=collateral_value,
        debt_value=debt_value,
        liquidity_value=liquidity_value,
        health_factor=health,
        max_borrow_value=max_borrow
    )

@external
@view
def account_row(account: address, asset: address) -> AccountRow:
    collateral_amount: uint256 = staticcall IPool(self.pool).collateral_balance(account, asset)
    debt_amount: uint256 = staticcall IPool(self.pool).debt_of(account, asset)
    return AccountRow(asset=asset, collateral_amount=collateral_amount, debt_amount=debt_amount)

@external
@view
def account_rows(account: address) -> DynArray[AccountRow, MAX_ASSETS]:
    rows: DynArray[AccountRow, MAX_ASSETS] = []
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        asset: address = self._asset_at(i)
        collateral_amount: uint256 = staticcall IPool(self.pool).collateral_balance(account, asset)
        debt_amount: uint256 = staticcall IPool(self.pool).debt_of(account, asset)
        rows.append(AccountRow(asset=asset, collateral_amount=collateral_amount, debt_amount=debt_amount))
    return rows

@external
@view
def aggregate_cash() -> uint256:
    total: uint256 = 0
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        row: MarketRow = self._market_row(self._asset_at(i))
        total += row.cash
    return total

@external
@view
def aggregate_borrows() -> uint256:
    total: uint256 = 0
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        row: MarketRow = self._market_row(self._asset_at(i))
        total += row.total_borrows
    return total

@external
@view
def aggregate_reserves() -> uint256:
    total: uint256 = 0
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        row: MarketRow = self._market_row(self._asset_at(i))
        total += row.total_reserves
    return total

@external
@view
def highest_utilization() -> (address, uint256):
    selected: address = empty(address)
    best: uint256 = 0
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        asset: address = self._asset_at(i)
        util: uint256 = staticcall IPool(self.pool).utilization(asset)
        if util > best:
            selected = asset
            best = util
    return selected, best

@external
@view
def lowest_liquidity_asset() -> (address, uint256):
    selected: address = empty(address)
    lowest: uint256 = max_value(uint256)
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        asset: address = self._asset_at(i)
        row: MarketRow = self._market_row(asset)
        if row.cash < lowest:
            selected = asset
            lowest = row.cash
    return selected, lowest

@external
@view
def has_debt(account: address) -> bool:
    count: uint256 = self._asset_count()
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        asset: address = self._asset_at(i)
        if staticcall IPool(self.pool).debt_of(account, asset) > 0:
            return True
    return False

@external
@view
def supplied_assets(account: address) -> uint256:
    count: uint256 = self._asset_count()
    supplied: uint256 = 0
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        asset: address = self._asset_at(i)
        if staticcall IPool(self.pool).collateral_balance(account, asset) > 0:
            supplied += 1
    return supplied

@external
@view
def borrowed_assets(account: address) -> uint256:
    count: uint256 = self._asset_count()
    borrowed: uint256 = 0
    for i: uint256 in range(MAX_ASSETS):
        if i >= count:
            break
        asset: address = self._asset_at(i)
        if staticcall IPool(self.pool).debt_of(account, asset) > 0:
            borrowed += 1
    return borrowed

@external
@view
def liquidation_preview(
    borrower: address,
    debt_asset: address,
    collateral_asset: address,
    max_repay: uint256
) -> (uint256, uint256, uint256):
    repay_amount: uint256 = 0
    seize_amount: uint256 = 0
    repay_amount, seize_amount = staticcall IPool(self.pool).preview_liquidation(
        borrower,
        debt_asset,
        collateral_asset,
        max_repay
    )
    health: uint256 = staticcall IPool(self.pool).health_factor(borrower)
    return repay_amount, seize_amount, health
