# pragma version ^0.4.3

WAD: constant(uint256) = 10**18
DEFAULT_STALE_AFTER: constant(uint256) = 86_400

struct PriceRecord:
    price_e18: uint256
    updated_at: uint256
    stale_after: uint256
    reporter: address
    live: bool

event ReporterSet:
    asset: indexed(address)
    reporter: indexed(address)

event PricePosted:
    asset: indexed(address)
    price_e18: uint256
    updated_at: uint256

event PriceStatusSet:
    asset: indexed(address)
    live: bool

owner: public(address)
records: public(HashMap[address, PriceRecord])
global_paused: public(bool)

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
def set_reporter(asset: address, reporter: address, stale_after: uint256):
    self._only_owner()
    assert asset != empty(address), "asset"
    assert reporter != empty(address), "reporter"
    window: uint256 = stale_after
    if window == 0:
        window = DEFAULT_STALE_AFTER
    self.records[asset].reporter = reporter
    self.records[asset].stale_after = window
    self.records[asset].live = True
    log ReporterSet(asset=asset, reporter=reporter)

@external
def set_global_pause(paused: bool):
    self._only_owner()
    self.global_paused = paused

@external
def set_asset_live(asset: address, live: bool):
    self._only_owner()
    self.records[asset].live = live
    log PriceStatusSet(asset=asset, live=live)

@external
def post_price(asset: address, price_e18: uint256):
    record: PriceRecord = self.records[asset]
    assert record.reporter == msg.sender or msg.sender == self.owner, "reporter"
    assert price_e18 > 0, "price"
    self.records[asset].price_e18 = price_e18
    self.records[asset].updated_at = block.timestamp
    if self.records[asset].stale_after == 0:
        self.records[asset].stale_after = DEFAULT_STALE_AFTER
    self.records[asset].live = True
    log PricePosted(asset=asset, price_e18=price_e18, updated_at=block.timestamp)

@external
@view
def get_price(asset: address) -> (uint256, uint256, bool):
    record: PriceRecord = self.records[asset]
    fresh: bool = False
    if not self.global_paused and record.live and record.price_e18 > 0:
        if block.timestamp <= record.updated_at + record.stale_after:
            fresh = True
    return record.price_e18, record.updated_at, fresh

@external
@view
def quote_value(asset: address, amount: uint256, unit: uint256) -> uint256:
    record: PriceRecord = self.records[asset]
    assert unit > 0, "unit"
    assert not self.global_paused, "paused"
    assert record.live, "live"
    assert record.price_e18 > 0, "price"
    assert block.timestamp <= record.updated_at + record.stale_after, "stale"
    return amount * record.price_e18 // unit

@external
@view
def is_fresh(asset: address) -> bool:
    record: PriceRecord = self.records[asset]
    if self.global_paused:
        return False
    if not record.live or record.price_e18 == 0:
        return False
    return block.timestamp <= record.updated_at + record.stale_after
