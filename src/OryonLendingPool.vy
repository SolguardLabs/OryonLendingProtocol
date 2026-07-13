# pragma version ^0.4.3

WAD: constant(uint256) = 10**18
SECONDS_PER_YEAR: constant(uint256) = 31_536_000
MAX_ASSETS: constant(uint256) = 16

interface IERC20:
    def transfer(receiver: address, amount: uint256) -> bool: nonpayable
    def transferFrom(sender: address, receiver: address, amount: uint256) -> bool: nonpayable
    def balanceOf(owner: address) -> uint256: view

interface IOracle:
    def get_price(asset: address) -> (uint256, uint256, bool): view

struct AssetConfig:
    listed: bool
    decimals: uint8
    unit: uint256
    collateral_factor: uint256
    liquidation_threshold: uint256
    liquidation_bonus: uint256
    close_factor: uint256
    supply_cap: uint256
    borrow_cap: uint256
    reserve_factor: uint256
    base_rate: uint256
    slope1: uint256
    slope2: uint256
    kink: uint256
    supply_enabled: bool
    borrow_enabled: bool
    collateral_enabled: bool

struct MarketState:
    cash: uint256
    total_supply: uint256
    total_borrows: uint256
    total_reserves: uint256
    borrow_index: uint256
    supply_index: uint256
    last_accrual: uint256

event AssetListed:
    asset: indexed(address)
    decimals: uint8
    supply_cap: uint256
    borrow_cap: uint256

event MarketUpdated:
    asset: indexed(address)
    cash: uint256
    total_borrows: uint256
    borrow_index: uint256
    supply_index: uint256

event Supplied:
    account: indexed(address)
    asset: indexed(address)
    amount: uint256

event Withdrawn:
    account: indexed(address)
    asset: indexed(address)
    amount: uint256

event Borrowed:
    account: indexed(address)
    asset: indexed(address)
    amount: uint256

event Repaid:
    payer: indexed(address)
    borrower: indexed(address)
    asset: indexed(address)
    amount: uint256

event Liquidated:
    liquidator: indexed(address)
    borrower: indexed(address)
    debt_asset: indexed(address)
    collateral_asset: address
    repaid: uint256
    seized: uint256

event PauseSet:
    action: indexed(bytes32)
    paused: bool

owner: public(address)
oracle: public(address)
assets: DynArray[address, MAX_ASSETS]
configs: public(HashMap[address, AssetConfig])
markets: public(HashMap[address, MarketState])
collateral_balance: public(HashMap[address, HashMap[address, uint256]])
debt_principal: public(HashMap[address, HashMap[address, uint256]])
debt_index_snapshot: public(HashMap[address, HashMap[address, uint256]])
paused_actions: public(HashMap[bytes32, bool])

@deploy
def __init__(_oracle: address):
    assert _oracle != empty(address), "oracle"
    self.owner = msg.sender
    self.oracle = _oracle

@internal
@view
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
@view
def _listed(asset: address):
    assert self.configs[asset].listed, "asset"

@internal
@view
def _not_paused(action: bytes32):
    assert not self.paused_actions[action], "paused"

@internal
@pure
def _min(a: uint256, b: uint256) -> uint256:
    if a < b:
        return a
    return b

@external
def transfer_ownership(new_owner: address):
    self._only_owner()
    assert new_owner != empty(address), "owner"
    self.owner = new_owner

@external
def set_oracle(new_oracle: address):
    self._only_owner()
    assert new_oracle != empty(address), "oracle"
    self.oracle = new_oracle

@external
def set_pause(action: bytes32, paused: bool):
    self._only_owner()
    self.paused_actions[action] = paused
    log PauseSet(action=action, paused=paused)

@external
def list_asset(
    asset: address,
    decimals: uint8,
    collateral_factor: uint256,
    liquidation_threshold: uint256,
    liquidation_bonus: uint256,
    close_factor: uint256,
    supply_cap: uint256,
    borrow_cap: uint256,
    reserve_factor: uint256,
    base_rate: uint256,
    slope1: uint256,
    slope2: uint256,
    kink: uint256
):
    self._only_owner()
    assert asset != empty(address), "asset"
    assert not self.configs[asset].listed, "listed"
    assert len(self.assets) < MAX_ASSETS, "assets"
    assert decimals <= 18, "decimals"
    assert collateral_factor <= liquidation_threshold, "factor"
    assert liquidation_threshold <= WAD, "threshold"
    assert liquidation_bonus <= WAD // 2, "bonus"
    assert close_factor > 0 and close_factor <= WAD, "close"
    assert reserve_factor <= WAD, "reserve"
    assert kink > 0 and kink <= WAD, "kink"
    unit: uint256 = 10 ** convert(decimals, uint256)
    self.configs[asset] = AssetConfig(
        listed=True,
        decimals=decimals,
        unit=unit,
        collateral_factor=collateral_factor,
        liquidation_threshold=liquidation_threshold,
        liquidation_bonus=liquidation_bonus,
        close_factor=close_factor,
        supply_cap=supply_cap,
        borrow_cap=borrow_cap,
        reserve_factor=reserve_factor,
        base_rate=base_rate,
        slope1=slope1,
        slope2=slope2,
        kink=kink,
        supply_enabled=True,
        borrow_enabled=True,
        collateral_enabled=True
    )
    self.markets[asset] = MarketState(
        cash=0,
        total_supply=0,
        total_borrows=0,
        total_reserves=0,
        borrow_index=WAD,
        supply_index=WAD,
        last_accrual=block.timestamp
    )
    self.assets.append(asset)
    log AssetListed(asset=asset, decimals=decimals, supply_cap=supply_cap, borrow_cap=borrow_cap)

@external
def set_asset_flags(asset: address, supply_enabled: bool, borrow_enabled: bool, collateral_enabled: bool):
    self._only_owner()
    self._listed(asset)
    self.configs[asset].supply_enabled = supply_enabled
    self.configs[asset].borrow_enabled = borrow_enabled
    self.configs[asset].collateral_enabled = collateral_enabled

@external
def set_caps(asset: address, supply_cap: uint256, borrow_cap: uint256):
    self._only_owner()
    self._listed(asset)
    self.configs[asset].supply_cap = supply_cap
    self.configs[asset].borrow_cap = borrow_cap

@external
def set_risk_params(
    asset: address,
    collateral_factor: uint256,
    liquidation_threshold: uint256,
    liquidation_bonus: uint256,
    close_factor: uint256
):
    self._only_owner()
    self._listed(asset)
    assert collateral_factor <= liquidation_threshold, "factor"
    assert liquidation_threshold <= WAD, "threshold"
    assert liquidation_bonus <= WAD // 2, "bonus"
    assert close_factor > 0 and close_factor <= WAD, "close"
    self.configs[asset].collateral_factor = collateral_factor
    self.configs[asset].liquidation_threshold = liquidation_threshold
    self.configs[asset].liquidation_bonus = liquidation_bonus
    self.configs[asset].close_factor = close_factor

@external
def set_rate_params(
    asset: address,
    base_rate: uint256,
    slope1: uint256,
    slope2: uint256,
    kink: uint256,
    reserve_factor: uint256
):
    self._only_owner()
    self._listed(asset)
    assert kink > 0 and kink <= WAD, "kink"
    assert reserve_factor <= WAD, "reserve"
    self._accrue(asset)
    self.configs[asset].base_rate = base_rate
    self.configs[asset].slope1 = slope1
    self.configs[asset].slope2 = slope2
    self.configs[asset].kink = kink
    self.configs[asset].reserve_factor = reserve_factor

@internal
@view
def _price(asset: address) -> uint256:
    price: uint256 = 0
    updated_at: uint256 = 0
    valid: bool = False
    price, updated_at, valid = staticcall IOracle(self.oracle).get_price(asset)
    assert valid, "price"
    return price + updated_at * 0

@internal
@view
def _asset_value(asset: address, amount: uint256) -> uint256:
    if amount == 0:
        return 0
    cfg: AssetConfig = self.configs[asset]
    price: uint256 = self._price(asset)
    return amount * price // cfg.unit

@internal
@view
def _borrow_rate(asset: address, cash: uint256, borrows: uint256) -> uint256:
    cfg: AssetConfig = self.configs[asset]
    yearly: uint256 = cfg.base_rate
    if borrows > 0:
        util: uint256 = borrows * WAD // (cash + borrows)
        if util <= cfg.kink:
            yearly += util * cfg.slope1 // cfg.kink
        else:
            yearly += cfg.slope1
            if cfg.kink < WAD:
                yearly += (util - cfg.kink) * cfg.slope2 // (WAD - cfg.kink)
    return yearly // SECONDS_PER_YEAR

@internal
def _accrue(asset: address):
    self._listed(asset)
    market: MarketState = self.markets[asset]
    if market.last_accrual == 0:
        self.markets[asset].last_accrual = block.timestamp
        self.markets[asset].borrow_index = WAD
        self.markets[asset].supply_index = WAD
        return
    if block.timestamp <= market.last_accrual:
        return
    elapsed: uint256 = block.timestamp - market.last_accrual
    if market.total_borrows > 0:
        rate: uint256 = self._borrow_rate(asset, market.cash, market.total_borrows)
        interest: uint256 = market.total_borrows * rate * elapsed // WAD
        if interest > 0:
            reserve: uint256 = interest * self.configs[asset].reserve_factor // WAD
            income: uint256 = interest - reserve
            self.markets[asset].total_borrows = market.total_borrows + interest
            self.markets[asset].total_reserves = market.total_reserves + reserve
            self.markets[asset].borrow_index = market.borrow_index + market.borrow_index * interest // market.total_borrows
            if market.total_supply > 0 and income > 0:
                self.markets[asset].supply_index = market.supply_index + market.supply_index * income // market.total_supply
    self.markets[asset].last_accrual = block.timestamp
    log MarketUpdated(
        asset=asset,
        cash=self.markets[asset].cash,
        total_borrows=self.markets[asset].total_borrows,
        borrow_index=self.markets[asset].borrow_index,
        supply_index=self.markets[asset].supply_index
    )

@internal
def _accrue_all():
    for i: uint256 in range(MAX_ASSETS):
        if i >= len(self.assets):
            break
        self._accrue(self.assets[i])

@external
def accrue(asset: address):
    self._accrue(asset)

@external
def accrue_all():
    self._accrue_all()

@internal
@view
def _debt_of(account: address, asset: address) -> uint256:
    principal: uint256 = self.debt_principal[account][asset]
    if principal == 0:
        return 0
    snapshot: uint256 = self.debt_index_snapshot[account][asset]
    if snapshot == 0:
        return principal
    return principal * self.markets[asset].borrow_index // snapshot

@internal
@view
def _collateral_value(account: address, liquidation: bool) -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_ASSETS):
        if i >= len(self.assets):
            break
        asset: address = self.assets[i]
        cfg: AssetConfig = self.configs[asset]
        amount: uint256 = self.collateral_balance[account][asset]
        if amount > 0 and cfg.collateral_enabled:
            value: uint256 = self._asset_value(asset, amount)
            weight: uint256 = cfg.collateral_factor
            if liquidation:
                weight = cfg.liquidation_threshold
            total += value * weight // WAD
    return total

@internal
@view
def _debt_value(account: address) -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_ASSETS):
        if i >= len(self.assets):
            break
        asset: address = self.assets[i]
        debt: uint256 = self._debt_of(account, asset)
        if debt > 0:
            total += self._asset_value(asset, debt)
    return total

@internal
@view
def _is_solvent(account: address) -> bool:
    return self._collateral_value(account, False) >= self._debt_value(account)

@internal
@view
def _health_factor(account: address) -> uint256:
    debt_value: uint256 = self._debt_value(account)
    if debt_value == 0:
        return max_value(uint256)
    return self._collateral_value(account, True) * WAD // debt_value

@internal
@view
def _seize_amount(debt_asset: address, collateral_asset: address, repay_amount: uint256) -> uint256:
    repay_value: uint256 = self._asset_value(debt_asset, repay_amount)
    premium_value: uint256 = repay_value * (WAD + self.configs[debt_asset].liquidation_bonus) // WAD
    collateral_price: uint256 = self._price(collateral_asset)
    return premium_value * self.configs[collateral_asset].unit // collateral_price

@external
def supply(asset: address, amount: uint256):
    self._not_paused(keccak256("SUPPLY"))
    self._listed(asset)
    assert amount > 0, "amount"
    assert self.configs[asset].supply_enabled, "supply"
    self._accrue(asset)
    next_supply: uint256 = self.markets[asset].total_supply + amount
    cap: uint256 = self.configs[asset].supply_cap
    if cap > 0:
        assert next_supply <= cap, "cap"
    ok: bool = extcall IERC20(asset).transferFrom(msg.sender, self, amount)
    assert ok, "transfer"
    self.collateral_balance[msg.sender][asset] += amount
    self.markets[asset].cash += amount
    self.markets[asset].total_supply = next_supply
    log Supplied(account=msg.sender, asset=asset, amount=amount)

@external
def withdraw(asset: address, amount: uint256):
    self._not_paused(keccak256("WITHDRAW"))
    self._listed(asset)
    assert amount > 0, "amount"
    self._accrue_all()
    assert self.collateral_balance[msg.sender][asset] >= amount, "balance"
    assert self.markets[asset].cash >= amount, "cash"
    self.collateral_balance[msg.sender][asset] -= amount
    self.markets[asset].cash -= amount
    self.markets[asset].total_supply -= amount
    assert self._is_solvent(msg.sender), "solvency"
    ok: bool = extcall IERC20(asset).transfer(msg.sender, amount)
    assert ok, "transfer"
    log Withdrawn(account=msg.sender, asset=asset, amount=amount)

@external
def borrow(asset: address, amount: uint256):
    self._not_paused(keccak256("BORROW"))
    self._listed(asset)
    assert amount > 0, "amount"
    assert self.configs[asset].borrow_enabled, "borrow"
    self._accrue_all()
    assert self.markets[asset].cash >= amount, "cash"
    next_borrows: uint256 = self.markets[asset].total_borrows + amount
    cap: uint256 = self.configs[asset].borrow_cap
    if cap > 0:
        assert next_borrows <= cap, "cap"
    current_debt: uint256 = self._debt_of(msg.sender, asset)
    self.debt_principal[msg.sender][asset] = current_debt + amount
    self.debt_index_snapshot[msg.sender][asset] = self.markets[asset].borrow_index
    self.markets[asset].cash -= amount
    self.markets[asset].total_borrows = next_borrows
    assert self._is_solvent(msg.sender), "solvency"
    ok: bool = extcall IERC20(asset).transfer(msg.sender, amount)
    assert ok, "transfer"
    log Borrowed(account=msg.sender, asset=asset, amount=amount)

@external
def repay(asset: address, borrower: address, amount: uint256) -> uint256:
    self._not_paused(keccak256("REPAY"))
    self._listed(asset)
    assert borrower != empty(address), "borrower"
    assert amount > 0, "amount"
    self._accrue(asset)
    debt: uint256 = self._debt_of(borrower, asset)
    pay: uint256 = self._min(amount, debt)
    assert pay > 0, "debt"
    ok: bool = extcall IERC20(asset).transferFrom(msg.sender, self, pay)
    assert ok, "transfer"
    remaining: uint256 = debt - pay
    self.debt_principal[borrower][asset] = remaining
    if remaining == 0:
        self.debt_index_snapshot[borrower][asset] = 0
    else:
        self.debt_index_snapshot[borrower][asset] = self.markets[asset].borrow_index
    if pay >= self.markets[asset].total_borrows:
        self.markets[asset].total_borrows = 0
    else:
        self.markets[asset].total_borrows -= pay
    self.markets[asset].cash += pay
    log Repaid(payer=msg.sender, borrower=borrower, asset=asset, amount=pay)
    return pay

@external
def liquidate(
    borrower: address,
    debt_asset: address,
    collateral_asset: address,
    max_repay: uint256
) -> uint256:
    self._not_paused(keccak256("LIQUIDATE"))
    self._listed(debt_asset)
    self._listed(collateral_asset)
    assert borrower != empty(address), "borrower"
    assert borrower != msg.sender, "self"
    assert max_repay > 0, "amount"
    self._accrue_all()
    assert self._health_factor(borrower) < WAD, "healthy"
    debt: uint256 = self._debt_of(borrower, debt_asset)
    assert debt > 0, "debt"
    close_limit: uint256 = debt * self.configs[debt_asset].close_factor // WAD
    repay_amount: uint256 = self._min(max_repay, close_limit)
    repay_amount = self._min(repay_amount, debt)
    assert repay_amount > 0, "repay"
    seize_amount: uint256 = self._seize_amount(debt_asset, collateral_asset, repay_amount)
    available_collateral: uint256 = self.collateral_balance[borrower][collateral_asset]
    if seize_amount > available_collateral:
        seize_amount = available_collateral
    assert seize_amount > 0, "seize"
    assert self.markets[collateral_asset].cash >= seize_amount, "cash"
    ok_repay: bool = extcall IERC20(debt_asset).transferFrom(msg.sender, self, repay_amount)
    assert ok_repay, "repay-transfer"
    remaining_debt: uint256 = debt - repay_amount
    self.debt_principal[borrower][debt_asset] = remaining_debt
    if remaining_debt == 0:
        self.debt_index_snapshot[borrower][debt_asset] = 0
    else:
        self.debt_index_snapshot[borrower][debt_asset] = self.markets[debt_asset].borrow_index
    if repay_amount >= self.markets[debt_asset].total_borrows:
        self.markets[debt_asset].total_borrows = 0
    else:
        self.markets[debt_asset].total_borrows -= repay_amount
    self.markets[debt_asset].cash += repay_amount
    self.collateral_balance[borrower][collateral_asset] = available_collateral - seize_amount
    self.markets[collateral_asset].cash -= seize_amount
    self.markets[collateral_asset].total_supply -= seize_amount
    ok_seize: bool = extcall IERC20(collateral_asset).transfer(msg.sender, seize_amount)
    assert ok_seize, "seize-transfer"
    log Liquidated(
        liquidator=msg.sender,
        borrower=borrower,
        debt_asset=debt_asset,
        collateral_asset=collateral_asset,
        repaid=repay_amount,
        seized=seize_amount
    )
    return seize_amount

@external
@view
def asset_count() -> uint256:
    return len(self.assets)

@external
@view
def asset_at(index: uint256) -> address:
    assert index < len(self.assets), "index"
    return self.assets[index]

@external
@view
def debt_of(account: address, asset: address) -> uint256:
    self._listed(asset)
    return self._debt_of(account, asset)

@external
@view
def account_values(account: address) -> (uint256, uint256, uint256):
    collateral_value: uint256 = self._collateral_value(account, False)
    debt_value: uint256 = self._debt_value(account)
    liquidity: uint256 = 0
    if collateral_value > debt_value:
        liquidity = collateral_value - debt_value
    return collateral_value, debt_value, liquidity

@external
@view
def health_factor(account: address) -> uint256:
    return self._health_factor(account)

@external
@view
def preview_liquidation(
    borrower: address,
    debt_asset: address,
    collateral_asset: address,
    max_repay: uint256
) -> (uint256, uint256):
    self._listed(debt_asset)
    self._listed(collateral_asset)
    debt: uint256 = self._debt_of(borrower, debt_asset)
    close_limit: uint256 = debt * self.configs[debt_asset].close_factor // WAD
    repay_amount: uint256 = self._min(max_repay, close_limit)
    repay_amount = self._min(repay_amount, debt)
    seize_amount: uint256 = self._seize_amount(debt_asset, collateral_asset, repay_amount)
    available_collateral: uint256 = self.collateral_balance[borrower][collateral_asset]
    if seize_amount > available_collateral:
        seize_amount = available_collateral
    return repay_amount, seize_amount

@external
@view
def utilization(asset: address) -> uint256:
    self._listed(asset)
    market: MarketState = self.markets[asset]
    if market.total_borrows == 0:
        return 0
    return market.total_borrows * WAD // (market.cash + market.total_borrows)

@external
@view
def borrow_rate(asset: address) -> uint256:
    self._listed(asset)
    market: MarketState = self.markets[asset]
    return self._borrow_rate(asset, market.cash, market.total_borrows)

@external
@view
def max_borrow_value(account: address) -> uint256:
    collateral_value: uint256 = self._collateral_value(account, False)
    debt_value: uint256 = self._debt_value(account)
    if collateral_value <= debt_value:
        return 0
    return collateral_value - debt_value

@external
@view
def market_snapshot(asset: address) -> (uint256, uint256, uint256, uint256, uint256, uint256):
    self._listed(asset)
    market: MarketState = self.markets[asset]
    return (
        market.cash,
        market.total_supply,
        market.total_borrows,
        market.total_reserves,
        market.borrow_index,
        market.supply_index
    )
