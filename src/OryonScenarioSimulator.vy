# pragma version ^0.4.3

WAD: constant(uint256) = 10**18
SECONDS_PER_YEAR: constant(uint256) = 31_536_000

struct Position:
    collateral_value: uint256
    liquidation_collateral_value: uint256
    debt_value: uint256

struct LiquidationTerms:
    close_factor: uint256
    liquidation_bonus: uint256
    debt_price: uint256
    collateral_price: uint256
    collateral_unit: uint256

@external
@pure
def health_factor(liquidation_collateral_value: uint256, debt_value: uint256) -> uint256:
    if debt_value == 0:
        return max_value(uint256)
    return liquidation_collateral_value * WAD // debt_value

@external
@pure
def liquidity(collateral_value: uint256, debt_value: uint256) -> int256:
    if collateral_value >= debt_value:
        return convert(collateral_value - debt_value, int256)
    return -convert(debt_value - collateral_value, int256)

@external
@pure
def apply_price_factor(notional_value: uint256, factor: uint256) -> uint256:
    return notional_value * factor // WAD

@external
@pure
def collateral_after_price_move(collateral_value: uint256, factor: uint256, weight: uint256) -> uint256:
    moved_value: uint256 = collateral_value * factor // WAD
    return moved_value * weight // WAD

@external
@pure
def debt_after_price_move(debt_value: uint256, factor: uint256) -> uint256:
    return debt_value * factor // WAD

@external
@pure
def position_after_borrow(collateral_value: uint256, debt_value: uint256, borrow_value: uint256) -> Position:
    return Position(
        collateral_value=collateral_value,
        liquidation_collateral_value=collateral_value,
        debt_value=debt_value + borrow_value
    )

@external
@pure
def position_after_repay(collateral_value: uint256, liquidation_collateral_value: uint256, debt_value: uint256, repay_value: uint256) -> Position:
    next_debt: uint256 = 0
    if repay_value < debt_value:
        next_debt = debt_value - repay_value
    return Position(
        collateral_value=collateral_value,
        liquidation_collateral_value=liquidation_collateral_value,
        debt_value=next_debt
    )

@external
@pure
def close_amount(debt_amount: uint256, close_factor: uint256) -> uint256:
    return debt_amount * close_factor // WAD

@external
@pure
def repay_value(repay_amount: uint256, debt_price: uint256, debt_unit: uint256) -> uint256:
    assert debt_unit > 0, "unit"
    return repay_amount * debt_price // debt_unit

@external
@pure
def collateral_amount_from_value(notional_value: uint256, collateral_price: uint256, collateral_unit: uint256) -> uint256:
    assert collateral_price > 0, "price"
    return notional_value * collateral_unit // collateral_price

@external
@pure
def liquidation_notional(repaid_value: uint256, liquidation_bonus: uint256) -> uint256:
    return repaid_value * (WAD + liquidation_bonus) // WAD

@external
@pure
def projected_liquidation(
    debt_amount: uint256,
    requested_repay: uint256,
    debt_price: uint256,
    debt_unit: uint256,
    collateral_price: uint256,
    collateral_unit: uint256,
    close_factor: uint256,
    liquidation_bonus: uint256
) -> (uint256, uint256, uint256):
    close_limit: uint256 = debt_amount * close_factor // WAD
    repay_amount: uint256 = requested_repay
    if repay_amount > close_limit:
        repay_amount = close_limit
    if repay_amount > debt_amount:
        repay_amount = debt_amount
    paid_value: uint256 = repay_amount * debt_price // debt_unit
    notional_value: uint256 = paid_value * (WAD + liquidation_bonus) // WAD
    collateral_amount: uint256 = notional_value * collateral_unit // collateral_price
    return repay_amount, paid_value, collateral_amount

@external
@pure
def interest_accrued(borrows: uint256, rate_per_second: uint256, elapsed: uint256) -> uint256:
    return borrows * rate_per_second * elapsed // WAD

@external
@pure
def borrow_index_after(index: uint256, borrows: uint256, interest: uint256) -> uint256:
    if borrows == 0:
        return index
    return index + index * interest // borrows

@external
@pure
def supply_index_after(index: uint256, total_supply: uint256, interest: uint256, reserve_factor: uint256) -> uint256:
    if total_supply == 0:
        return index
    income: uint256 = interest * (WAD - reserve_factor) // WAD
    return index + index * income // total_supply

@external
@pure
def utilization(cash: uint256, borrows: uint256) -> uint256:
    if borrows == 0:
        return 0
    return borrows * WAD // (cash + borrows)

@external
@pure
def utilization_after_delta(cash: uint256, borrows: uint256, borrow_delta: uint256, repay_delta: uint256) -> uint256:
    next_cash: uint256 = cash
    next_borrows: uint256 = borrows
    if borrow_delta > 0:
        if borrow_delta >= next_cash:
            next_cash = 0
        else:
            next_cash -= borrow_delta
        next_borrows += borrow_delta
    if repay_delta > 0:
        paid: uint256 = repay_delta
        if paid > next_borrows:
            paid = next_borrows
        next_cash += paid
        next_borrows -= paid
    if next_borrows == 0:
        return 0
    return next_borrows * WAD // (next_cash + next_borrows)

@external
@pure
def borrow_capacity(collateral_value: uint256, debt_value: uint256) -> uint256:
    if collateral_value <= debt_value:
        return 0
    return collateral_value - debt_value

@external
@pure
def withdrawal_capacity(collateral_value: uint256, debt_value: uint256, asset_weight: uint256) -> uint256:
    if asset_weight == 0 or collateral_value <= debt_value:
        return 0
    return (collateral_value - debt_value) * WAD // asset_weight

@external
@pure
def solvency_after_withdraw(collateral_value: uint256, debt_value: uint256, withdraw_value: uint256, weight: uint256) -> bool:
    weighted_withdraw: uint256 = withdraw_value * weight // WAD
    if weighted_withdraw >= collateral_value:
        return debt_value == 0
    return collateral_value - weighted_withdraw >= debt_value

@external
@pure
def solvency_after_borrow(collateral_value: uint256, debt_value: uint256, borrow_value: uint256) -> bool:
    return collateral_value >= debt_value + borrow_value

@external
@pure
def market_after_accrual(cash: uint256, borrows: uint256, reserves: uint256, interest: uint256, reserve_factor: uint256) -> (uint256, uint256, uint256):
    reserve_income: uint256 = interest * reserve_factor // WAD
    return cash, borrows + interest, reserves + reserve_income

@external
@pure
def liquidation_improves_health(
    liquidation_collateral_value: uint256,
    debt_value: uint256,
    seized_value: uint256,
    repaid_value: uint256
) -> bool:
    if debt_value <= repaid_value:
        return True
    if liquidation_collateral_value <= seized_value:
        return False
    before_hf: uint256 = liquidation_collateral_value * WAD // debt_value
    after_hf: uint256 = (liquidation_collateral_value - seized_value) * WAD // (debt_value - repaid_value)
    return after_hf >= before_hf

@external
@pure
def risk_band(health_factor_value: uint256) -> uint256:
    if health_factor_value == max_value(uint256):
        return 0
    if health_factor_value < WAD:
        return 5
    if health_factor_value < WAD * 110 // 100:
        return 4
    if health_factor_value < WAD * 125 // 100:
        return 3
    if health_factor_value < WAD * 150 // 100:
        return 2
    return 1
