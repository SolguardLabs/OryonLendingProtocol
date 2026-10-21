import json
from decimal import Decimal
from pathlib import Path

import pytest

from client.risk_console import Market, decimal, project, read_snapshot, stringify


SNAPSHOT = Path(__file__).parent / "fixtures" / "portfolio.json"


def test_curve_and_reserve_projection():
    markets, _ = read_snapshot(SNAPSHOT)
    usdc = markets["USDC"]
    assert usdc.utilization() == Decimal("0.12")
    assert usdc.borrow_apr() == Decimal("0.03")
    assert usdc.supply_apr() == Decimal("0.00324")
    assert usdc.reserve_projection(Decimal(31_536_000)) == Decimal("360")


def test_stress_projection_reduces_health_and_keeps_base_immutable():
    result = project(SNAPSHOT, horizon_days=Decimal(30), shocks={"WETH": Decimal("0.70")})
    assert result["account"]["liquidation_capacity_usd"] == Decimal("16000")
    assert Decimal("1.3333") < result["account"]["health_factor"] < Decimal("1.3334")
    assert result["account"]["available_borrow_usd"] == Decimal("2400")
    assert result["stressed_account"]["liquidation_buffer_usd"] == Decimal("-800")
    assert result["stressed_account"]["health_factor"] < Decimal(1)
    assert result["markets"]["USDC"]["projected_reserves"] > 0


def test_kink_boundary_and_steep_segment():
    document = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    source = document["markets"]["USDC"]
    source["cash"] = "20"
    source["borrows"] = "80"
    source["reserves"] = "1"
    market = Market.parse("USDC", source)
    assert market.utilization() == Decimal("0.8")
    assert market.borrow_apr() == Decimal("0.20")
    source["cash"] = "10"
    market = Market.parse("USDC", source)
    assert market.borrow_apr() > Decimal("0.20")


@pytest.mark.parametrize("invalid", ["nan", "Infinity", "-1", 1.5, True])
def test_invalid_decimals_rejected(invalid):
    with pytest.raises(ValueError):
        decimal(invalid, "sample")


def test_unlisted_symbol_and_horizon_rejected(tmp_path):
    document = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    document["positions"]["UNKNOWN"] = {"supplied": "1"}
    path = tmp_path / "snapshot.json"
    path.write_text(json.dumps(document), encoding="utf-8")
    with pytest.raises(ValueError, match="unknown markets"):
        read_snapshot(path)
    with pytest.raises(ValueError, match="horizon"):
        project(SNAPSHOT, horizon_days=Decimal(366), shocks={})


def test_serialization_uses_decimal_strings():
    result = project(SNAPSHOT, horizon_days=Decimal(7), shocks={})
    output = stringify(result)
    assert isinstance(output["markets"]["USDC"]["borrow_apr"], str)
    assert output["markets"]["USDC"]["borrow_apr"] == "0.03000000"
