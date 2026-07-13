# pragma version ^0.4.3

WAD: constant(uint256) = 10**18
MAX_ASSETS: constant(uint256) = 32
MAX_TEMPLATES: constant(uint256) = 32

struct RiskTemplate:
    collateral_factor: uint256
    liquidation_threshold: uint256
    liquidation_bonus: uint256
    close_factor: uint256
    supply_cap: uint256
    borrow_cap: uint256
    reserve_factor: uint256
    max_price_age: uint256
    min_depth: uint256
    enabled: bool

struct AssetPolicy:
    template_id: bytes32
    isolation_mode: bool
    can_supply: bool
    can_borrow: bool
    can_collateralize: bool
    debt_ceiling_value: uint256
    liquidation_grace: uint256
    keeper_limit: uint256
    review_after: uint256
    enabled: bool

event TemplateSet:
    template_id: indexed(bytes32)
    collateral_factor: uint256
    liquidation_threshold: uint256
    liquidation_bonus: uint256
    close_factor: uint256

event PolicySet:
    asset: indexed(address)
    template_id: indexed(bytes32)
    isolation_mode: bool
    enabled: bool

event AssetFlagSet:
    asset: indexed(address)
    can_supply: bool
    can_borrow: bool
    can_collateralize: bool

owner: public(address)
templates: public(HashMap[bytes32, RiskTemplate])
policies: public(HashMap[address, AssetPolicy])
template_ids: DynArray[bytes32, MAX_TEMPLATES]
assets: DynArray[address, MAX_ASSETS]

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

@external
def transfer_ownership(new_owner: address):
    self._only_owner()
    assert new_owner != empty(address), "owner"
    self.owner = new_owner

@external
def set_template(
    template_id: bytes32,
    collateral_factor: uint256,
    liquidation_threshold: uint256,
    liquidation_bonus: uint256,
    close_factor: uint256,
    supply_cap: uint256,
    borrow_cap: uint256,
    reserve_factor: uint256,
    max_price_age: uint256,
    min_depth: uint256
):
    self._only_owner()
    assert template_id != empty(bytes32), "template"
    assert collateral_factor <= liquidation_threshold, "factor"
    assert liquidation_threshold <= WAD, "threshold"
    assert liquidation_bonus <= WAD // 2, "bonus"
    assert close_factor > 0 and close_factor <= WAD, "close"
    assert reserve_factor <= WAD, "reserve"
    if not self.templates[template_id].enabled:
        assert len(self.template_ids) < MAX_TEMPLATES, "templates"
        self.template_ids.append(template_id)
    self.templates[template_id] = RiskTemplate(
        collateral_factor=collateral_factor,
        liquidation_threshold=liquidation_threshold,
        liquidation_bonus=liquidation_bonus,
        close_factor=close_factor,
        supply_cap=supply_cap,
        borrow_cap=borrow_cap,
        reserve_factor=reserve_factor,
        max_price_age=max_price_age,
        min_depth=min_depth,
        enabled=True
    )
    log TemplateSet(
        template_id=template_id,
        collateral_factor=collateral_factor,
        liquidation_threshold=liquidation_threshold,
        liquidation_bonus=liquidation_bonus,
        close_factor=close_factor
    )

@external
def set_policy(
    asset: address,
    template_id: bytes32,
    isolation_mode: bool,
    debt_ceiling_value: uint256,
    liquidation_grace: uint256,
    keeper_limit: uint256,
    review_after: uint256
):
    self._only_owner()
    assert asset != empty(address), "asset"
    assert self.templates[template_id].enabled, "template"
    if not self.policies[asset].enabled:
        assert len(self.assets) < MAX_ASSETS, "assets"
        self.assets.append(asset)
    self.policies[asset] = AssetPolicy(
        template_id=template_id,
        isolation_mode=isolation_mode,
        can_supply=True,
        can_borrow=True,
        can_collateralize=True,
        debt_ceiling_value=debt_ceiling_value,
        liquidation_grace=liquidation_grace,
        keeper_limit=keeper_limit,
        review_after=review_after,
        enabled=True
    )
    log PolicySet(asset=asset, template_id=template_id, isolation_mode=isolation_mode, enabled=True)

@external
def set_asset_flags(asset: address, can_supply: bool, can_borrow: bool, can_collateralize: bool):
    self._only_owner()
    assert self.policies[asset].enabled, "policy"
    self.policies[asset].can_supply = can_supply
    self.policies[asset].can_borrow = can_borrow
    self.policies[asset].can_collateralize = can_collateralize
    log AssetFlagSet(
        asset=asset,
        can_supply=can_supply,
        can_borrow=can_borrow,
        can_collateralize=can_collateralize
    )

@external
def set_debt_controls(asset: address, debt_ceiling_value: uint256, keeper_limit: uint256):
    self._only_owner()
    assert self.policies[asset].enabled, "policy"
    self.policies[asset].debt_ceiling_value = debt_ceiling_value
    self.policies[asset].keeper_limit = keeper_limit

@external
def set_review_window(asset: address, review_after: uint256, liquidation_grace: uint256):
    self._only_owner()
    assert self.policies[asset].enabled, "policy"
    self.policies[asset].review_after = review_after
    self.policies[asset].liquidation_grace = liquidation_grace

@external
def disable_policy(asset: address):
    self._only_owner()
    self.policies[asset].enabled = False

@external
@view
def template_count() -> uint256:
    return len(self.template_ids)

@external
@view
def template_at(index: uint256) -> bytes32:
    assert index < len(self.template_ids), "index"
    return self.template_ids[index]

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
def effective_params(asset: address) -> (uint256, uint256, uint256, uint256, uint256, uint256, uint256):
    policy: AssetPolicy = self.policies[asset]
    assert policy.enabled, "policy"
    template: RiskTemplate = self.templates[policy.template_id]
    assert template.enabled, "template"
    return (
        template.collateral_factor,
        template.liquidation_threshold,
        template.liquidation_bonus,
        template.close_factor,
        template.supply_cap,
        template.borrow_cap,
        template.reserve_factor
    )

@external
@view
def can_open_borrow(asset: address, market_borrow_value: uint256, requested_value: uint256) -> bool:
    policy: AssetPolicy = self.policies[asset]
    if not policy.enabled or not policy.can_borrow:
        return False
    if policy.debt_ceiling_value > 0:
        if market_borrow_value + requested_value > policy.debt_ceiling_value:
            return False
    return True

@external
@view
def can_accept_supply(asset: address, market_supply: uint256, requested_supply: uint256) -> bool:
    policy: AssetPolicy = self.policies[asset]
    if not policy.enabled or not policy.can_supply:
        return False
    template: RiskTemplate = self.templates[policy.template_id]
    if template.supply_cap > 0:
        if market_supply + requested_supply > template.supply_cap:
            return False
    return True

@external
@view
def can_use_as_collateral(asset: address) -> bool:
    policy: AssetPolicy = self.policies[asset]
    if not policy.enabled:
        return False
    return policy.can_collateralize

@external
@view
def close_limit(asset: address, debt_amount: uint256) -> uint256:
    policy: AssetPolicy = self.policies[asset]
    if not policy.enabled:
        return 0
    template: RiskTemplate = self.templates[policy.template_id]
    return debt_amount * template.close_factor // WAD

@external
@view
def liquidation_value(asset: address, repay_value: uint256) -> uint256:
    policy: AssetPolicy = self.policies[asset]
    if not policy.enabled:
        return 0
    template: RiskTemplate = self.templates[policy.template_id]
    return repay_value * (WAD + template.liquidation_bonus) // WAD

@external
@view
def weighted_collateral_value(asset: address, raw_value: uint256) -> uint256:
    policy: AssetPolicy = self.policies[asset]
    if not policy.enabled:
        return 0
    template: RiskTemplate = self.templates[policy.template_id]
    return raw_value * template.collateral_factor // WAD

@external
@view
def liquidation_threshold_value(asset: address, raw_value: uint256) -> uint256:
    policy: AssetPolicy = self.policies[asset]
    if not policy.enabled:
        return 0
    template: RiskTemplate = self.templates[policy.template_id]
    return raw_value * template.liquidation_threshold // WAD

@external
@view
def template_is_conservative(template_id: bytes32) -> bool:
    template: RiskTemplate = self.templates[template_id]
    if not template.enabled:
        return False
    if template.collateral_factor > WAD * 80 // 100:
        return False
    if template.liquidation_threshold > WAD * 90 // 100:
        return False
    if template.liquidation_bonus > WAD * 15 // 100:
        return False
    return True

@external
@view
def policy_needs_review(asset: address) -> bool:
    policy: AssetPolicy = self.policies[asset]
    if not policy.enabled:
        return False
    if policy.review_after == 0:
        return False
    return block.timestamp >= policy.review_after

@external
@view
def keeper_repay_limit(asset: address, debt_amount: uint256) -> uint256:
    policy: AssetPolicy = self.policies[asset]
    if not policy.enabled:
        return 0
    template: RiskTemplate = self.templates[policy.template_id]
    close_amount: uint256 = debt_amount * template.close_factor // WAD
    if policy.keeper_limit == 0:
        return close_amount
    return self._min(close_amount, policy.keeper_limit)

@external
@view
def aggregate_debt_ceiling() -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_ASSETS):
        if i >= len(self.assets):
            break
        total += self.policies[self.assets[i]].debt_ceiling_value
    return total

@external
@view
def enabled_assets() -> uint256:
    count: uint256 = 0
    for i: uint256 in range(MAX_ASSETS):
        if i >= len(self.assets):
            break
        if self.policies[self.assets[i]].enabled:
            count += 1
    return count

@external
@view
def isolated_assets() -> uint256:
    count: uint256 = 0
    for i: uint256 in range(MAX_ASSETS):
        if i >= len(self.assets):
            break
        if self.policies[self.assets[i]].enabled and self.policies[self.assets[i]].isolation_mode:
            count += 1
    return count
