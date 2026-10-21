"""Deterministic market and account projections from exported snapshots.

The console never signs transactions and does not replace on-chain checks.
Amounts are supplied as human-readable token units, not base units.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, ROUND_DOWN, localcontext
from pathlib import Path
from typing import Any


ONE = Decimal(1)
YEAR = Decimal(31_536_000)


def decimal(value: object, field: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (str, int, Decimal)):
        raise ValueError(f"{field}: decimal string or integer required")
    try:
        result = Decimal(value)
    except InvalidOperation as exc:
        raise ValueError(f"{field}: invalid decimal") from exc
    if not result.is_finite() or result < 0:
        raise ValueError(f"{field}: finite non-negative value required")
    return result


def ratio(value: object, field: str) -> Decimal:
    result = decimal(value, field)
    if result > ONE:
        raise ValueError(f"{field}: ratio must be within [0, 1]")
    return result


@dataclass(frozen=True)
class Market:
    symbol: str
    price: Decimal
    cash: Decimal
    borrows: Decimal
    reserves: Decimal
    base_rate: Decimal
    slope1: Decimal
    slope2: Decimal
    kink: Decimal
    reserve_factor: Decimal
    collateral_factor: Decimal
    liquidation_threshold: Decimal

    @classmethod
    def parse(cls, symbol: str, source: dict[str, Any]) -> Market:
        if not symbol or not symbol.isascii() or len(symbol) > 16:
            raise ValueError("market symbol must contain 1-16 ASCII characters")
        if not isinstance(source, dict):
            raise ValueError(f"{symbol}: market object required")
        values = {key: decimal(source[key], f"{symbol}.{key}") for key in (
            "price", "cash", "borrows", "reserves", "base_rate", "slope1", "slope2"
        )}
        for key in ("kink", "reserve_factor", "collateral_factor", "liquidation_threshold"):
            values[key] = ratio(source[key], f"{symbol}.{key}")
        if values["price"] == 0 or values["kink"] == 0:
            raise ValueError(f"{symbol}: positive price and kink required")
        if values["reserves"] > values["cash"] + values["borrows"]:
            raise ValueError(f"{symbol}: reserves exceed gross assets")
        if values["collateral_factor"] > values["liquidation_threshold"]:
            raise ValueError(f"{symbol}: collateral factor exceeds liquidation threshold")
        return cls(symbol=symbol, **values)

    def utilization(self) -> Decimal:
        denominator = self.cash + self.borrows
        return self.borrows / denominator if denominator else Decimal(0)

    def borrow_apr(self) -> Decimal:
        utilization = self.utilization()
        if utilization <= self.kink:
            return self.base_rate + self.slope1 * utilization / self.kink
        return self.base_rate + self.slope1 + self.slope2 * (utilization - self.kink) / (ONE - self.kink)

    def supply_apr(self) -> Decimal:
        return self.borrow_apr() * self.utilization() * (ONE - self.reserve_factor)

    def reserve_projection(self, seconds: Decimal) -> Decimal:
        return self.borrows * self.borrow_apr() * self.reserve_factor * seconds / YEAR


@dataclass(frozen=True)
class Position:
    symbol: str
    supplied: Decimal
    borrowed: Decimal

    @classmethod
    def parse(cls, symbol: str, source: dict[str, Any]) -> Position:
        if not isinstance(source, dict):
            raise ValueError(f"{symbol}: position object required")
        return cls(
            symbol=symbol,
            supplied=decimal(source.get("supplied", "0"), f"{symbol}.supplied"),
            borrowed=decimal(source.get("borrowed", "0"), f"{symbol}.borrowed"),
        )


def account_projection(
    markets: dict[str, Market], positions: list[Position], price_shocks: dict[str, Decimal]
) -> dict[str, Decimal | None]:
    borrowing_power = Decimal(0)
    liquidation_capacity = Decimal(0)
    debt_value = Decimal(0)
    for position in positions:
        market = markets[position.symbol]
        shock = price_shocks.get(position.symbol, ONE)
        if shock < 0:
            raise ValueError(f"{position.symbol}: price shock must be non-negative")
        price = market.price * shock
        borrowing_power += position.supplied * price * market.collateral_factor
        liquidation_capacity += position.supplied * price * market.liquidation_threshold
        debt_value += position.borrowed * price
    return {
        "borrowing_power_usd": borrowing_power,
        "liquidation_capacity_usd": liquidation_capacity,
        "debt_usd": debt_value,
        "available_borrow_usd": max(Decimal(0), borrowing_power - debt_value),
        "liquidation_buffer_usd": liquidation_capacity - debt_value,
        "health_factor": liquidation_capacity / debt_value if debt_value else None,
    }


def read_snapshot(path: Path) -> tuple[dict[str, Market], list[Position]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise ValueError("snapshot object required")
    raw_markets = document.get("markets")
    raw_positions = document.get("positions")
    if not isinstance(raw_markets, dict) or not isinstance(raw_positions, dict):
        raise ValueError("markets and positions must be objects")
    if not raw_markets:
        raise ValueError("at least one market required")
    markets = {symbol: Market.parse(symbol, value) for symbol, value in raw_markets.items()}
    unknown = set(raw_positions) - set(markets)
    if unknown:
        raise ValueError(f"positions reference unknown markets: {sorted(unknown)}")
    positions = [Position.parse(symbol, value) for symbol, value in raw_positions.items()]
    return markets, positions


def project(path: Path, *, horizon_days: Decimal, shocks: dict[str, Decimal]) -> dict[str, Any]:
    if horizon_days < 0 or horizon_days > 365:
        raise ValueError("horizon days must be within [0, 365]")
    markets, positions = read_snapshot(path)
    unknown = set(shocks) - set(markets)
    if unknown:
        raise ValueError(f"price shocks reference unknown markets: {sorted(unknown)}")
    with localcontext() as context:
        context.prec = 48
        market_report = {
            symbol: {
                "utilization": market.utilization(),
                "borrow_apr": market.borrow_apr(),
                "supply_apr": market.supply_apr(),
                "projected_reserves": market.reserve_projection(horizon_days * Decimal(86_400)),
            }
            for symbol, market in markets.items()
        }
        return {
            "horizon_days": horizon_days,
            "markets": market_report,
            "account": account_projection(markets, positions, {}),
            "stressed_account": account_projection(markets, positions, shocks),
        }


def stringify(value: Any) -> Any:
    if isinstance(value, Decimal):
        with localcontext() as context:
            context.prec = 48
            return format(value.quantize(Decimal("0.00000001"), rounding=ROUND_DOWN), "f")
    if isinstance(value, dict):
        return {key: stringify(item) for key, item in value.items()}
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description="Read-only Oryon market risk projection")
    parser.add_argument("snapshot", type=Path)
    parser.add_argument("--days", default="30", help="projection horizon, 0-365 days")
    parser.add_argument("--shock", action="append", default=[], metavar="SYMBOL=MULTIPLIER")
    args = parser.parse_args()
    shocks: dict[str, Decimal] = {}
    for item in args.shock:
        if "=" not in item:
            parser.error("each --shock must use SYMBOL=MULTIPLIER")
        symbol, value = item.split("=", 1)
        shocks[symbol] = decimal(value, f"shock {symbol}")
    try:
        report = project(args.snapshot, horizon_days=decimal(args.days, "days"), shocks=shocks)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    print(json.dumps(stringify(report), indent=2, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
