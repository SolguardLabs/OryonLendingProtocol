# pragma version ^0.4.3

WAD: constant(uint256) = 10**18
MAX_ASSETS: constant(uint256) = 32
MAX_KEEPERS: constant(uint256) = 16

struct Bucket:
    supplied: uint256
    withdrawn: uint256
    borrowed: uint256
    repaid: uint256
    liquidated_debt: uint256
    seized_collateral: uint256
    reserve_income: uint256
    last_update: uint256

struct AccountStats:
    supplied_value: uint256
    borrowed_value: uint256
    repaid_value: uint256
    liquidation_count: uint256
    last_seen: uint256
    active: bool

event KeeperSet:
    keeper: indexed(address)
    allowed: bool

event FlowRecorded:
    asset: indexed(address)
    account: indexed(address)
    bucket: uint256
    kind: bytes32
    amount: uint256
    value: uint256

owner: public(address)
keepers: public(HashMap[address, bool])
keeper_list: DynArray[address, MAX_KEEPERS]
asset_list: DynArray[address, MAX_ASSETS]
asset_seen: HashMap[address, bool]
buckets: public(HashMap[address, HashMap[uint256, Bucket]])
account_stats: public(HashMap[address, AccountStats])

@deploy
def __init__():
    self.owner = msg.sender
    self.keepers[msg.sender] = True
    self.keeper_list.append(msg.sender)

@internal
@view
def _only_owner():
    assert msg.sender == self.owner, "owner"

@internal
@view
def _only_keeper():
    assert self.keepers[msg.sender], "keeper"

@internal
def _touch_asset(asset: address):
    if not self.asset_seen[asset]:
        assert len(self.asset_list) < MAX_ASSETS, "assets"
        self.asset_seen[asset] = True
        self.asset_list.append(asset)

@internal
@pure
def _bucket_id(timestamp: uint256) -> uint256:
    return timestamp // 86_400

@external
def transfer_ownership(new_owner: address):
    self._only_owner()
    assert new_owner != empty(address), "owner"
    self.owner = new_owner

@external
def set_keeper(keeper: address, allowed: bool):
    self._only_owner()
    assert keeper != empty(address), "keeper"
    if allowed and not self.keepers[keeper]:
        assert len(self.keeper_list) < MAX_KEEPERS, "keepers"
        self.keeper_list.append(keeper)
    self.keepers[keeper] = allowed
    log KeeperSet(keeper=keeper, allowed=allowed)

@external
def record_supply(asset: address, account: address, amount: uint256, notional_value: uint256):
    self._only_keeper()
    self._touch_asset(asset)
    bucket: uint256 = self._bucket_id(block.timestamp)
    self.buckets[asset][bucket].supplied += amount
    self.buckets[asset][bucket].last_update = block.timestamp
    self.account_stats[account].supplied_value += notional_value
    self.account_stats[account].last_seen = block.timestamp
    self.account_stats[account].active = True
    log FlowRecorded(asset=asset, account=account, bucket=bucket, kind=keccak256("SUPPLY"), amount=amount, value=notional_value)

@external
def record_withdraw(asset: address, account: address, amount: uint256, notional_value: uint256):
    self._only_keeper()
    self._touch_asset(asset)
    bucket: uint256 = self._bucket_id(block.timestamp)
    self.buckets[asset][bucket].withdrawn += amount
    self.buckets[asset][bucket].last_update = block.timestamp
    if self.account_stats[account].supplied_value > notional_value:
        self.account_stats[account].supplied_value -= notional_value
    else:
        self.account_stats[account].supplied_value = 0
    self.account_stats[account].last_seen = block.timestamp
    log FlowRecorded(asset=asset, account=account, bucket=bucket, kind=keccak256("WITHDRAW"), amount=amount, value=notional_value)

@external
def record_borrow(asset: address, account: address, amount: uint256, notional_value: uint256):
    self._only_keeper()
    self._touch_asset(asset)
    bucket: uint256 = self._bucket_id(block.timestamp)
    self.buckets[asset][bucket].borrowed += amount
    self.buckets[asset][bucket].last_update = block.timestamp
    self.account_stats[account].borrowed_value += notional_value
    self.account_stats[account].last_seen = block.timestamp
    self.account_stats[account].active = True
    log FlowRecorded(asset=asset, account=account, bucket=bucket, kind=keccak256("BORROW"), amount=amount, value=notional_value)

@external
def record_repay(asset: address, account: address, amount: uint256, notional_value: uint256):
    self._only_keeper()
    self._touch_asset(asset)
    bucket: uint256 = self._bucket_id(block.timestamp)
    self.buckets[asset][bucket].repaid += amount
    self.buckets[asset][bucket].last_update = block.timestamp
    if self.account_stats[account].borrowed_value > notional_value:
        self.account_stats[account].borrowed_value -= notional_value
    else:
        self.account_stats[account].borrowed_value = 0
    self.account_stats[account].repaid_value += notional_value
    self.account_stats[account].last_seen = block.timestamp
    log FlowRecorded(asset=asset, account=account, bucket=bucket, kind=keccak256("REPAY"), amount=amount, value=notional_value)

@external
def record_liquidation(
    debt_asset: address,
    collateral_asset: address,
    borrower: address,
    repaid_amount: uint256,
    repaid_value: uint256,
    seized_amount: uint256,
    seized_value: uint256
):
    self._only_keeper()
    self._touch_asset(debt_asset)
    self._touch_asset(collateral_asset)
    bucket: uint256 = self._bucket_id(block.timestamp)
    self.buckets[debt_asset][bucket].liquidated_debt += repaid_amount
    self.buckets[collateral_asset][bucket].seized_collateral += seized_amount
    self.buckets[debt_asset][bucket].last_update = block.timestamp
    self.buckets[collateral_asset][bucket].last_update = block.timestamp
    if self.account_stats[borrower].borrowed_value > repaid_value:
        self.account_stats[borrower].borrowed_value -= repaid_value
    else:
        self.account_stats[borrower].borrowed_value = 0
    if self.account_stats[borrower].supplied_value > seized_value:
        self.account_stats[borrower].supplied_value -= seized_value
    else:
        self.account_stats[borrower].supplied_value = 0
    self.account_stats[borrower].liquidation_count += 1
    self.account_stats[borrower].last_seen = block.timestamp
    log FlowRecorded(asset=debt_asset, account=borrower, bucket=bucket, kind=keccak256("LIQUIDATE"), amount=repaid_amount, value=repaid_value)

@external
def record_reserve_income(asset: address, amount: uint256):
    self._only_keeper()
    self._touch_asset(asset)
    bucket: uint256 = self._bucket_id(block.timestamp)
    self.buckets[asset][bucket].reserve_income += amount
    self.buckets[asset][bucket].last_update = block.timestamp

@external
@view
def keeper_count() -> uint256:
    return len(self.keeper_list)

@external
@view
def keeper_at(index: uint256) -> address:
    assert index < len(self.keeper_list), "index"
    return self.keeper_list[index]

@external
@view
def asset_count() -> uint256:
    return len(self.asset_list)

@external
@view
def asset_at(index: uint256) -> address:
    assert index < len(self.asset_list), "index"
    return self.asset_list[index]

@external
@view
def current_bucket() -> uint256:
    return self._bucket_id(block.timestamp)

@external
@view
def bucket_net_supply(asset: address, bucket: uint256) -> int256:
    b: Bucket = self.buckets[asset][bucket]
    if b.supplied >= b.withdrawn:
        return convert(b.supplied - b.withdrawn, int256)
    return -convert(b.withdrawn - b.supplied, int256)

@external
@view
def bucket_net_debt(asset: address, bucket: uint256) -> int256:
    b: Bucket = self.buckets[asset][bucket]
    outflow: uint256 = b.repaid + b.liquidated_debt
    if b.borrowed >= outflow:
        return convert(b.borrowed - outflow, int256)
    return -convert(outflow - b.borrowed, int256)

@external
@view
def bucket_activity_score(asset: address, bucket: uint256) -> uint256:
    b: Bucket = self.buckets[asset][bucket]
    return b.supplied + b.withdrawn + b.borrowed + b.repaid + b.liquidated_debt + b.seized_collateral

@external
@view
def account_net_value(account: address) -> int256:
    stats: AccountStats = self.account_stats[account]
    if stats.supplied_value >= stats.borrowed_value:
        return convert(stats.supplied_value - stats.borrowed_value, int256)
    return -convert(stats.borrowed_value - stats.supplied_value, int256)

@external
@view
def account_is_active(account: address, max_idle: uint256) -> bool:
    stats: AccountStats = self.account_stats[account]
    if not stats.active:
        return False
    if max_idle == 0:
        return True
    return block.timestamp <= stats.last_seen + max_idle

@external
@view
def rolling_activity(asset: address, start_bucket: uint256, count: uint256) -> uint256:
    total: uint256 = 0
    limit: uint256 = count
    if limit > 14:
        limit = 14
    for i: uint256 in range(14):
        if i >= limit:
            break
        b: Bucket = self.buckets[asset][start_bucket + i]
        total += b.supplied + b.withdrawn + b.borrowed + b.repaid + b.liquidated_debt + b.seized_collateral
    return total
