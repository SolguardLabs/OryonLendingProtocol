# pragma version ^0.4.3

WAD: constant(uint256) = 10**18
SECONDS_PER_YEAR: constant(uint256) = 31_536_000
MAX_POINTS: constant(uint256) = 16

struct Curve:
    base_rate: uint256
    slope1: uint256
    slope2: uint256
    kink: uint256
    reserve_factor: uint256
    enabled: bool

event CurveSet:
    asset: indexed(address)
    base_rate: uint256
    slope1: uint256
    slope2: uint256
    kink: uint256
    reserve_factor: uint256

owner: public(address)
curves: public(HashMap[address, Curve])
tracked_assets: DynArray[address, MAX_POINTS]

@deploy
def __init__():
    self.owner = msg.sender

@internal
@view
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
@pure
def _min(a: uint256, b: uint256) -> uint256:
    if a < b:
        return a
    return b

@internal
@pure
def _max(a: uint256, b: uint256) -> uint256:
    if a > b:
        return a
    return b

@external
def transfer_ownership(new_owner: address):
    self._only_owner()
    assert new_owner != empty(address), "owner"
    self.owner = new_owner

@external
def set_curve(
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
    if not self.curves[asset].enabled:
        assert len(self.tracked_assets) < MAX_POINTS, "assets"
        self.tracked_assets.append(asset)
    self.curves[asset] = Curve(
        base_rate=base_rate,
        slope1=slope1,
        slope2=slope2,
        kink=kink,
        reserve_factor=reserve_factor,
        enabled=True
    )
    log CurveSet(
        asset=asset,
        base_rate=base_rate,
        slope1=slope1,
        slope2=slope2,
        kink=kink,
        reserve_factor=reserve_factor
    )

@external
def disable_curve(asset: address):
    self._only_owner()
    self.curves[asset].enabled = False

@internal
@view
def _utilization(cash: uint256, borrows: uint256) -> uint256:
    if borrows == 0:
        return 0
    return borrows * WAD // (cash + borrows)

@internal
@view
def _borrow_rate_for_curve(curve: Curve, cash: uint256, borrows: uint256) -> uint256:
    if not curve.enabled:
        return 0
    yearly: uint256 = curve.base_rate
    if borrows > 0:
        util: uint256 = self._utilization(cash, borrows)
        if util <= curve.kink:
            yearly += util * curve.slope1 // curve.kink
        else:
            yearly += curve.slope1
            if curve.kink < WAD:
                yearly += (util - curve.kink) * curve.slope2 // (WAD - curve.kink)
    return yearly // SECONDS_PER_YEAR

@internal
@view
def _supply_rate_for_curve(curve: Curve, cash: uint256, borrows: uint256) -> uint256:
    if borrows == 0 or not curve.enabled:
        return 0
    util: uint256 = self._utilization(cash, borrows)
    borrow_rate: uint256 = self._borrow_rate_for_curve(curve, cash, borrows)
    return borrow_rate * util // WAD * (WAD - curve.reserve_factor) // WAD

@external
@view
def utilization(cash: uint256, borrows: uint256) -> uint256:
    return self._utilization(cash, borrows)

@external
@view
def borrow_rate(asset: address, cash: uint256, borrows: uint256) -> uint256:
    return self._borrow_rate_for_curve(self.curves[asset], cash, borrows)

@external
@view
def supply_rate(asset: address, cash: uint256, borrows: uint256) -> uint256:
    return self._supply_rate_for_curve(self.curves[asset], cash, borrows)

@external
@view
def yearly_borrow_rate(asset: address, cash: uint256, borrows: uint256) -> uint256:
    return self._borrow_rate_for_curve(self.curves[asset], cash, borrows) * SECONDS_PER_YEAR

@external
@view
def yearly_supply_rate(asset: address, cash: uint256, borrows: uint256) -> uint256:
    return self._supply_rate_for_curve(self.curves[asset], cash, borrows) * SECONDS_PER_YEAR

@external
@view
def utilization_after_borrow(cash: uint256, borrows: uint256, amount: uint256) -> uint256:
    if amount >= cash:
        return WAD
    return self._utilization(cash - amount, borrows + amount)

@external
@view
def utilization_after_repay(cash: uint256, borrows: uint256, amount: uint256) -> uint256:
    paid: uint256 = self._min(amount, borrows)
    return self._utilization(cash + paid, borrows - paid)

@external
@view
def borrow_rate_after_borrow(asset: address, cash: uint256, borrows: uint256, amount: uint256) -> uint256:
    if amount >= cash:
        return self._borrow_rate_for_curve(self.curves[asset], 0, borrows + amount)
    return self._borrow_rate_for_curve(self.curves[asset], cash - amount, borrows + amount)

@external
@view
def borrow_rate_after_repay(asset: address, cash: uint256, borrows: uint256, amount: uint256) -> uint256:
    paid: uint256 = self._min(amount, borrows)
    return self._borrow_rate_for_curve(self.curves[asset], cash + paid, borrows - paid)

@external
@view
def projected_interest(asset: address, cash: uint256, borrows: uint256, elapsed: uint256) -> uint256:
    return self._projected_interest(asset, cash, borrows, elapsed)

@internal
@view
def _projected_interest(asset: address, cash: uint256, borrows: uint256, elapsed: uint256) -> uint256:
    if borrows == 0 or elapsed == 0:
        return 0
    rate: uint256 = self._borrow_rate_for_curve(self.curves[asset], cash, borrows)
    return borrows * rate * elapsed // WAD

@external
@view
def projected_reserves(asset: address, cash: uint256, borrows: uint256, elapsed: uint256) -> uint256:
    interest: uint256 = self._projected_interest(asset, cash, borrows, elapsed)
    return interest * self.curves[asset].reserve_factor // WAD

@external
@view
def projected_supplier_income(asset: address, cash: uint256, borrows: uint256, elapsed: uint256) -> uint256:
    interest: uint256 = self._projected_interest(asset, cash, borrows, elapsed)
    reserves: uint256 = interest * self.curves[asset].reserve_factor // WAD
    return interest - reserves

@external
@view
def projected_borrow_index(asset: address, cash: uint256, borrows: uint256, index: uint256, elapsed: uint256) -> uint256:
    if borrows == 0 or elapsed == 0:
        return index
    interest: uint256 = self._projected_interest(asset, cash, borrows, elapsed)
    return index + index * interest // borrows

@external
@view
def projected_supply_index(
    asset: address,
    cash: uint256,
    borrows: uint256,
    total_supply: uint256,
    index: uint256,
    elapsed: uint256
) -> uint256:
    if total_supply == 0 or borrows == 0 or elapsed == 0:
        return index
    interest: uint256 = self._projected_interest(asset, cash, borrows, elapsed)
    reserves: uint256 = interest * self.curves[asset].reserve_factor // WAD
    income: uint256 = interest - reserves
    return index + index * income // total_supply

@external
@view
def rate_band(asset: address, cash: uint256, borrows: uint256) -> uint256:
    curve: Curve = self.curves[asset]
    util: uint256 = self._utilization(cash, borrows)
    if util == 0:
        return 0
    if util < curve.kink // 2:
        return 1
    if util < curve.kink:
        return 2
    if util < (curve.kink + WAD) // 2:
        return 3
    return 4

@external
@view
def curve_health(asset: address) -> (bool, bool, bool):
    curve: Curve = self.curves[asset]
    valid_kink: bool = curve.kink > 0 and curve.kink <= WAD
    valid_reserve: bool = curve.reserve_factor <= WAD
    valid_slopes: bool = curve.slope2 >= curve.slope1
    return valid_kink, valid_reserve, valid_slopes

@external
@view
def tracked_count() -> uint256:
    return len(self.tracked_assets)

@external
@view
def tracked_at(index: uint256) -> address:
    assert index < len(self.tracked_assets), "index"
    return self.tracked_assets[index]

@external
@view
def utilization_grid(cash: uint256, borrows: uint256, step: uint256) -> DynArray[uint256, MAX_POINTS]:
    assert step > 0, "step"
    result: DynArray[uint256, MAX_POINTS] = []
    for i: uint256 in range(MAX_POINTS):
        amount: uint256 = step * i
        if amount >= cash:
            result.append(WAD)
        else:
            result.append(self._utilization(cash - amount, borrows + amount))
    return result

@external
@view
def borrow_rate_grid(asset: address, cash: uint256, borrows: uint256, step: uint256) -> DynArray[uint256, MAX_POINTS]:
    assert step > 0, "step"
    result: DynArray[uint256, MAX_POINTS] = []
    curve: Curve = self.curves[asset]
    for i: uint256 in range(MAX_POINTS):
        amount: uint256 = step * i
        if amount >= cash:
            result.append(self._borrow_rate_for_curve(curve, 0, borrows + amount))
        else:
            result.append(self._borrow_rate_for_curve(curve, cash - amount, borrows + amount))
    return result
