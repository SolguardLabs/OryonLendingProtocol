import boa
import pytest


WAD = 10**18
USDC = 10**6
WETH = 10**18
WBTC = 10**8
YEAR = 31_536_000


def wad(value: float) -> int:
    return int(value * WAD)


@pytest.fixture()
def accounts():
    return {
        "owner": boa.env.generate_address("owner"),
        "lender": boa.env.generate_address("lender"),
        "borrower": boa.env.generate_address("borrower"),
        "liquidator": boa.env.generate_address("liquidator"),
        "keeper": boa.env.generate_address("keeper"),
    }


@pytest.fixture()
def protocol(accounts):
    owner = accounts["owner"]
    with boa.env.prank(owner):
        usdc = boa.load("src/MockERC20.vy", "Oryon USD", "oUSDC", 6)
        weth = boa.load("src/MockERC20.vy", "Oryon Ether", "oWETH", 18)
        wbtc = boa.load("src/MockERC20.vy", "Oryon Bitcoin", "oWBTC", 8)
        oracle = boa.load("src/OryonOracle.vy")
        pool = boa.load("src/OryonLendingPool.vy", oracle.address)

        for token in (usdc, weth, wbtc):
            oracle.set_reporter(token.address, owner, 7 * 24 * 60 * 60)

        oracle.post_price(usdc.address, WAD)
        oracle.post_price(weth.address, 2_000 * WAD)
        oracle.post_price(wbtc.address, 40_000 * WAD)

        pool.list_asset(
            usdc.address,
            6,
            wad(0.78),
            wad(0.84),
            wad(0.20),
            wad(0.50),
            2_000_000 * USDC,
            1_500_000 * USDC,
            wad(0.10),
            wad(0.00),
            wad(0.20),
            wad(1.50),
            wad(0.80),
        )
        pool.list_asset(
            weth.address,
            18,
            wad(0.72),
            wad(0.80),
            wad(0.05),
            wad(0.50),
            5_000 * WETH,
            2_500 * WETH,
            wad(0.10),
            wad(0.00),
            wad(0.18),
            wad(1.20),
            wad(0.80),
        )
        pool.list_asset(
            wbtc.address,
            8,
            wad(0.70),
            wad(0.78),
            wad(0.08),
            wad(0.50),
            1_000 * WBTC,
            500 * WBTC,
            wad(0.10),
            wad(0.00),
            wad(0.16),
            wad(1.00),
            wad(0.80),
        )

        usdc.mint(accounts["lender"], 1_000_000 * USDC)
        usdc.mint(accounts["liquidator"], 100_000 * USDC)
        weth.mint(accounts["borrower"], 20 * WETH)
        weth.mint(accounts["lender"], 25 * WETH)
        wbtc.mint(accounts["borrower"], 2 * WBTC)

    return {
        "pool": pool,
        "oracle": oracle,
        "usdc": usdc,
        "weth": weth,
        "wbtc": wbtc,
        **accounts,
    }


def approve_and_supply(token, pool, account, amount):
    with boa.env.prank(account):
        token.approve(pool.address, amount)
        pool.supply(token.address, amount)


def test_supply_updates_cash_and_collateral(protocol):
    pool = protocol["pool"]
    usdc = protocol["usdc"]
    lender = protocol["lender"]

    approve_and_supply(usdc, pool, lender, 250_000 * USDC)

    cash, total_supply, total_borrows, reserves, borrow_index, supply_index = pool.market_snapshot(
        usdc.address
    )
    assert cash == 250_000 * USDC
    assert total_supply == 250_000 * USDC
    assert total_borrows == 0
    assert reserves == 0
    assert borrow_index == WAD
    assert supply_index == WAD
    assert pool.collateral_balance(lender, usdc.address) == 250_000 * USDC


def test_borrow_consumes_liquidity_and_records_variable_debt(protocol):
    pool = protocol["pool"]
    usdc = protocol["usdc"]
    weth = protocol["weth"]
    lender = protocol["lender"]
    borrower = protocol["borrower"]

    approve_and_supply(usdc, pool, lender, 200_000 * USDC)
    approve_and_supply(weth, pool, borrower, 10 * WETH)

    with boa.env.prank(borrower):
        pool.borrow(usdc.address, 12_000 * USDC)

    cash, _, total_borrows, _, borrow_index, _ = pool.market_snapshot(usdc.address)
    collateral_value, debt_value, liquidity = pool.account_values(borrower)

    assert cash == 188_000 * USDC
    assert total_borrows == 12_000 * USDC
    assert borrow_index == WAD
    assert pool.debt_of(borrower, usdc.address) == 12_000 * USDC
    assert debt_value == 12_000 * WAD
    assert collateral_value == 14_400 * WAD
    assert liquidity == 2_400 * WAD
    assert usdc.balanceOf(borrower) == 12_000 * USDC


def test_repay_reduces_debt_and_restores_cash(protocol):
    pool = protocol["pool"]
    usdc = protocol["usdc"]
    weth = protocol["weth"]
    lender = protocol["lender"]
    borrower = protocol["borrower"]

    approve_and_supply(usdc, pool, lender, 200_000 * USDC)
    approve_and_supply(weth, pool, borrower, 10 * WETH)

    with boa.env.prank(borrower):
        pool.borrow(usdc.address, 8_000 * USDC)
        usdc.approve(pool.address, 3_000 * USDC)
        paid = pool.repay(usdc.address, borrower, 3_000 * USDC)

    cash, _, total_borrows, _, _, _ = pool.market_snapshot(usdc.address)
    assert paid == 3_000 * USDC
    assert pool.debt_of(borrower, usdc.address) == 5_000 * USDC
    assert total_borrows == 5_000 * USDC
    assert cash == 195_000 * USDC


def test_accrue_updates_indices_and_debt(protocol):
    pool = protocol["pool"]
    usdc = protocol["usdc"]
    weth = protocol["weth"]
    lender = protocol["lender"]
    borrower = protocol["borrower"]

    approve_and_supply(usdc, pool, lender, 100_000 * USDC)
    approve_and_supply(weth, pool, borrower, 10 * WETH)

    with boa.env.prank(borrower):
        pool.borrow(usdc.address, 12_000 * USDC)

    before = pool.market_snapshot(usdc.address)
    boa.env.time_travel(seconds=45 * 24 * 60 * 60)
    pool.accrue(usdc.address)
    after = pool.market_snapshot(usdc.address)

    assert after[4] > before[4]
    assert after[5] > before[5]
    assert after[2] > before[2]
    assert pool.debt_of(borrower, usdc.address) > 12_000 * USDC


def test_liquidation_reduces_debt_and_transfers_collateral(protocol):
    pool = protocol["pool"]
    oracle = protocol["oracle"]
    usdc = protocol["usdc"]
    weth = protocol["weth"]
    lender = protocol["lender"]
    borrower = protocol["borrower"]
    liquidator = protocol["liquidator"]
    owner = protocol["owner"]

    approve_and_supply(usdc, pool, lender, 200_000 * USDC)
    approve_and_supply(weth, pool, borrower, 10 * WETH)

    with boa.env.prank(borrower):
        pool.borrow(usdc.address, 12_000 * USDC)

    with boa.env.prank(owner):
        oracle.post_price(weth.address, 1_400 * WAD)

    assert pool.health_factor(borrower) < WAD
    repay_amount, quoted_seize = pool.preview_liquidation(
        borrower, usdc.address, weth.address, 3_000 * USDC
    )

    with boa.env.prank(liquidator):
        usdc.approve(pool.address, repay_amount)
        seized = pool.liquidate(borrower, usdc.address, weth.address, repay_amount)

    assert seized == quoted_seize
    assert pool.debt_of(borrower, usdc.address) == 9_000 * USDC
    assert weth.balanceOf(liquidator) == seized
    assert pool.collateral_balance(borrower, weth.address) == 10 * WETH - seized
    assert pool.health_factor(borrower) > 0
