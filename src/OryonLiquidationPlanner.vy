# pragma version ^0.4.3

WAD: constant(uint256) = 10**18
MAX_PLANS: constant(uint256) = 64

interface IPool:
    def health_factor(account: address) -> uint256: view
    def preview_liquidation(borrower: address, debt_asset: address, collateral_asset: address, max_repay: uint256) -> (uint256, uint256): view
    def debt_of(account: address, asset: address) -> uint256: view
    def collateral_balance(account: address, asset: address) -> uint256: view

struct RoutePolicy:
    debt_asset: address
    collateral_asset: address
    keeper: address
    min_repay: uint256
    max_repay: uint256
    min_seize: uint256
    max_health: uint256
    ttl: uint256
    enabled: bool

struct Plan:
    route_id: bytes32
    borrower: address
    keeper: address
    repay_amount: uint256
    seize_amount: uint256
    health_factor: uint256
    created_at: uint256
    expires_at: uint256
    active: bool
    used: bool

event RoutePolicySet:
    route_id: indexed(bytes32)
    debt_asset: indexed(address)
    collateral_asset: indexed(address)
    keeper: address

event PlanStored:
    plan_id: indexed(bytes32)
    route_id: indexed(bytes32)
    borrower: indexed(address)
    repay_amount: uint256
    seize_amount: uint256

event PlanStatusSet:
    plan_id: indexed(bytes32)
    active: bool
    used: bool

owner: public(address)
pool: public(address)
route_ids: DynArray[bytes32, MAX_PLANS]
plan_ids: DynArray[bytes32, MAX_PLANS]
routes: public(HashMap[bytes32, RoutePolicy])
plans: public(HashMap[bytes32, Plan])

@deploy
def __init__(_pool: address):
    assert _pool != empty(address), "pool"
    self.owner = msg.sender
    self.pool = _pool

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
def set_pool(new_pool: address):
    self._only_owner()
    assert new_pool != empty(address), "pool"
    self.pool = new_pool

@external
def set_route(
    route_id: bytes32,
    debt_asset: address,
    collateral_asset: address,
    keeper: address,
    min_repay: uint256,
    max_repay: uint256,
    min_seize: uint256,
    max_health: uint256,
    ttl: uint256
):
    self._only_owner()
    assert route_id != empty(bytes32), "route"
    assert debt_asset != empty(address), "debt"
    assert collateral_asset != empty(address), "collateral"
    assert max_health <= WAD, "health"
    assert ttl > 0, "ttl"
    if not self.routes[route_id].enabled:
        assert len(self.route_ids) < MAX_PLANS, "routes"
        self.route_ids.append(route_id)
    self.routes[route_id] = RoutePolicy(
        debt_asset=debt_asset,
        collateral_asset=collateral_asset,
        keeper=keeper,
        min_repay=min_repay,
        max_repay=max_repay,
        min_seize=min_seize,
        max_health=max_health,
        ttl=ttl,
        enabled=True
    )
    log RoutePolicySet(route_id=route_id, debt_asset=debt_asset, collateral_asset=collateral_asset, keeper=keeper)

@external
def disable_route(route_id: bytes32):
    self._only_owner()
    self.routes[route_id].enabled = False

@internal
@view
def _quote(route_id: bytes32, borrower: address, requested_repay: uint256) -> (uint256, uint256, uint256, bool):
    route: RoutePolicy = self.routes[route_id]
    if not route.enabled:
        return 0, 0, 0, False
    if route.keeper != empty(address) and route.keeper != msg.sender:
        return 0, 0, 0, False
    health: uint256 = staticcall IPool(self.pool).health_factor(borrower)
    if health >= route.max_health:
        return 0, 0, health, False
    repay_cap: uint256 = requested_repay
    if route.max_repay > 0 and repay_cap > route.max_repay:
        repay_cap = route.max_repay
    repay_amount: uint256 = 0
    seize_amount: uint256 = 0
    repay_amount, seize_amount = staticcall IPool(self.pool).preview_liquidation(
        borrower,
        route.debt_asset,
        route.collateral_asset,
        repay_cap
    )
    if repay_amount < route.min_repay:
        return repay_amount, seize_amount, health, False
    if seize_amount < route.min_seize:
        return repay_amount, seize_amount, health, False
    return repay_amount, seize_amount, health, True

@external
@view
def quote(route_id: bytes32, borrower: address, requested_repay: uint256) -> (uint256, uint256, uint256, bool):
    return self._quote(route_id, borrower, requested_repay)

@external
def store_plan(plan_id: bytes32, route_id: bytes32, borrower: address, requested_repay: uint256):
    assert plan_id != empty(bytes32), "plan"
    assert borrower != empty(address), "borrower"
    repay_amount: uint256 = 0
    seize_amount: uint256 = 0
    health: uint256 = 0
    ready: bool = False
    repay_amount, seize_amount, health, ready = self._quote(route_id, borrower, requested_repay)
    assert ready, "ready"
    if not self.plans[plan_id].active and not self.plans[plan_id].used:
        assert len(self.plan_ids) < MAX_PLANS, "plans"
        self.plan_ids.append(plan_id)
    route: RoutePolicy = self.routes[route_id]
    self.plans[plan_id] = Plan(
        route_id=route_id,
        borrower=borrower,
        keeper=msg.sender,
        repay_amount=repay_amount,
        seize_amount=seize_amount,
        health_factor=health,
        created_at=block.timestamp,
        expires_at=block.timestamp + route.ttl,
        active=True,
        used=False
    )
    log PlanStored(plan_id=plan_id, route_id=route_id, borrower=borrower, repay_amount=repay_amount, seize_amount=seize_amount)

@external
def refresh_plan(plan_id: bytes32, requested_repay: uint256):
    plan: Plan = self.plans[plan_id]
    assert plan.active, "plan"
    assert plan.keeper == msg.sender or msg.sender == self.owner, "keeper"
    repay_amount: uint256 = 0
    seize_amount: uint256 = 0
    health: uint256 = 0
    ready: bool = False
    repay_amount, seize_amount, health, ready = self._quote(plan.route_id, plan.borrower, requested_repay)
    assert ready, "ready"
    route: RoutePolicy = self.routes[plan.route_id]
    self.plans[plan_id].repay_amount = repay_amount
    self.plans[plan_id].seize_amount = seize_amount
    self.plans[plan_id].health_factor = health
    self.plans[plan_id].created_at = block.timestamp
    self.plans[plan_id].expires_at = block.timestamp + route.ttl
    log PlanStored(plan_id=plan_id, route_id=plan.route_id, borrower=plan.borrower, repay_amount=repay_amount, seize_amount=seize_amount)

@external
def cancel_plan(plan_id: bytes32):
    plan: Plan = self.plans[plan_id]
    assert plan.active, "plan"
    assert plan.keeper == msg.sender or msg.sender == self.owner, "keeper"
    self.plans[plan_id].active = False
    log PlanStatusSet(plan_id=plan_id, active=False, used=plan.used)

@external
def mark_used(plan_id: bytes32):
    plan: Plan = self.plans[plan_id]
    assert plan.active, "plan"
    assert plan.keeper == msg.sender or msg.sender == self.owner, "keeper"
    self.plans[plan_id].active = False
    self.plans[plan_id].used = True
    log PlanStatusSet(plan_id=plan_id, active=False, used=True)

@external
@view
def plan_ready(plan_id: bytes32) -> bool:
    plan: Plan = self.plans[plan_id]
    if not plan.active or plan.used:
        return False
    if block.timestamp > plan.expires_at:
        return False
    health: uint256 = staticcall IPool(self.pool).health_factor(plan.borrower)
    route: RoutePolicy = self.routes[plan.route_id]
    return health < route.max_health

@external
@view
def route_count() -> uint256:
    return len(self.route_ids)

@external
@view
def route_at(index: uint256) -> bytes32:
    assert index < len(self.route_ids), "index"
    return self.route_ids[index]

@external
@view
def plan_count() -> uint256:
    return len(self.plan_ids)

@external
@view
def plan_at(index: uint256) -> bytes32:
    assert index < len(self.plan_ids), "index"
    return self.plan_ids[index]

@external
@view
def open_plan_count() -> uint256:
    total: uint256 = 0
    for i: uint256 in range(MAX_PLANS):
        if i >= len(self.plan_ids):
            break
        if self.plans[self.plan_ids[i]].active and not self.plans[self.plan_ids[i]].used:
            total += 1
    return total
