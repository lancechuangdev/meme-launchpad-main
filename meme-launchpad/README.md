# Meme Launchpad Rebuild

This folder is a learning rebuild of the parent Solidity project. The original
contracts stay untouched.

## Roadmap

1. Token + CREATE2 factory
2. Core initialization, roles, and dependency wiring
3. Signed token creation request
4. Bonding curve buy/sell flow
5. Initial buy and vesting
6. Graduation and DEX liquidity flow
7. Admin controls, pause, blacklist, and fee updates

## Checkpoints

### Step 1: Token + CREATE2 Factory

- `LearningMEMEToken`: ERC20 token minted to the core address with transfer modes.
- `LearningMEMEFactory`: CREATE2 factory with predictable token addresses.
- `Step01FactoryAndToken.t.sol`: tests for deployment, address prediction, roles,
  and transfer restrictions.

### Step 2: Core Wiring + Roles

- `LearningMEMECore`: initializer-style setup for factory/helper/vesting-facing
  dependencies, role assignment, chain ID, and default fee parameters.
- `deployTokenForLearning`: a temporary learning function that proves the runtime
  call path is `admin -> core -> factory -> token`.
- `Step02CoreWiring.t.sol`: tests for one-time initialization, roles, defaults,
  factory permissions, and admin-only dependency updates.

### Step 3: Signed Token Creation

- `CreateTokenParams`: the ABI-encoded request that a trusted backend signer
  authorizes and any user can submit.
- `createToken`: verifies the signature, request expiry, replay ID, creation fee,
  and basic token parameters before deploying through the factory.
- The signed digest includes `data`, `chainId`, and the core address, so the same
  signature cannot be reused for a different request, chain, or core contract.
- `Step03SignedTokenCreation.t.sol`: tests successful creation and registration,
  fee forwarding/refunds, invalid signatures, expiration, and replay protection.

### Step 4: Bonding Curve Buy/Sell

- `LearningMEMEHelper`: pure constant-product calculations using `x * y = k`.
- Signed creation now initializes virtual reserves, real sale inventory, and the
  amount of native currency actually collected by the curve.
- `buy` and `sell`: enforce launch time, deadlines, slippage, trading fees, and
  real-liquidity limits while updating both virtual and real reserve accounting.
- `calculateBuyAmountWithFee` is quote function, it perform the same calculation as `buy` but it do not execute a trade or change contract state. A frontend calls it before `buy` to display the trading fee and choose slippage protection:
  ```
  (uint256 quotedTokens,,) =
      core.calculateBuyAmountWithFee(token, 1 ether);

  uint256 minTokens = quotedTokens * 95 / 100;

  core.buy{value: 1 ether}(
      token,
      minTokens,
      block.timestamp + 5 minutes
  );
  ``` 
- `Step04BondingCurveTrading.t.sol`: tests quotes, reserve updates, round-trip
  trading, fee transfers, slippage, launch timing, and insufficient liquidity.

### Step 5: Initial Buy + Vesting

- Signed creation can include an initial creator purchase expressed in basis
  points of total supply, with its exact curve cost and pre-buy fee.
- The curve begins from post-purchase virtual reserves and records the initial
  BNB as real collected liquidity before public trading starts.
- `LearningMEMEVesting` supports CLIFF and LINEAR schedules created only by the
  core, with beneficiary claims calculated from elapsed time.
- Initial tokens not assigned to vesting are transferred directly to the
  creator; vested tokens are held by the vesting contract until claimable.
- `Step05InitialBuyAndVesting.t.sol` covers direct initial purchases, payment,
  curve state, cliff unlocks, linear claims, and invalid allocations.

### Step 6: Graduation + DEX Liquidity

- A curve enters `PENDING_GRADUATION` when fewer than ten sale tokens remain,
  stopping bonding-curve trades while liquidity is prepared.
- `LearningDEXRouter` creates a local `LearningLiquidityPool`, transfers token
  and native reserves into it, and mints permanently locked LP tokens.
- `graduateToken` distributes platform and creator graduation fees, deposits the
  remaining assets as liquidity, records the pair, and enables normal transfers.
- `Step06GraduationAndLiquidity.t.sol` covers the threshold transition, role and
  status checks, fee distribution, pair reserves, LP locking, and final state.

### Step 7: Admin + Emergency Controls

- Global pause stops token creation and curve buy/sell operations while leaving
  recovery and administration available; pausers stop, but only admins resume.
- Per-token pause temporarily freezes a trading curve, while blacklist freezes
  any existing token and later restores its exact previous lifecycle state.
- Admin setters update fee receivers, fee rates, and minimum vesting duration
  with the same upper bounds as the original protocol.
- `Step07AdminAndEmergencyControls.t.sol` covers role separation, global and
  token-specific freezes, blacklist restoration, valid updates, and limit checks.

Run it with:

```bash
forge test --root meme-launchpad-rebuild
```
