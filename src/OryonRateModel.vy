# pragma version ^0.4.3

WAD: constant(uint256) = 10**18
SECONDS_PER_YEAR: constant(uint256) = 31_536_000

struct RateParams:
    base_rate: uint256
    slope1: uint256
    slope2: uint256
    kink: uint256
    reserve_factor: uint256
    live: bool

event RateParamsSet:
    asset: indexed(address)
    base_rate: uint256
    slope1: uint256
    slope2: uint256
    kink: uint256
    reserve_factor: uint256

owner: public(address)
params: public(HashMap[address, RateParams])

@deploy
def __init__():
    self.owner = msg.sender

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
def set_params(
    asset: address,
    base_rate: uint256,
    slope1: uint256,
    slope2: uint256,
    kink: uint256,
    reserve_factor: uint256
):
    self._only_owner()
    assert asset != empty(address), "asset"
    assert kink > 0 and kink <= WAD, "kink"
    assert reserve_factor <= WAD, "reserve"
    self.params[asset] = RateParams(
        base_rate=base_rate,
        slope1=slope1,
        slope2=slope2,
        kink=kink,
        reserve_factor=reserve_factor,
        live=True
    )
    log RateParamsSet(
        asset=asset,
        base_rate=base_rate,
        slope1=slope1,
        slope2=slope2,
        kink=kink,
        reserve_factor=reserve_factor
    )

@external
@view
def utilization(cash: uint256, borrows: uint256) -> uint256:
    if borrows == 0:
        return 0
    total: uint256 = cash + borrows
    if total == 0:
        return 0
    return borrows * WAD // total

@internal
@view
def _borrow_rate(asset: address, cash: uint256, borrows: uint256) -> uint256:
    p: RateParams = self.params[asset]
    if not p.live:
        return 0
    util: uint256 = 0
    if borrows > 0:
        util = borrows * WAD // (cash + borrows)
    yearly: uint256 = p.base_rate
    if util <= p.kink:
        yearly += util * p.slope1 // p.kink
    else:
        yearly += p.slope1
        yearly += (util - p.kink) * p.slope2 // (WAD - p.kink)
    return yearly // SECONDS_PER_YEAR

@external
@view
def borrow_rate(asset: address, cash: uint256, borrows: uint256) -> uint256:
    return self._borrow_rate(asset, cash, borrows)

@external
@view
def supply_rate(asset: address, cash: uint256, borrows: uint256) -> uint256:
    p: RateParams = self.params[asset]
    if not p.live or borrows == 0:
        return 0
    util: uint256 = borrows * WAD // (cash + borrows)
    borrow_per_second: uint256 = self._borrow_rate(asset, cash, borrows)
    gross: uint256 = borrow_per_second * util // WAD
    return gross * (WAD - p.reserve_factor) // WAD

@external
@view
def reserve_factor(asset: address) -> uint256:
    return self.params[asset].reserve_factor
