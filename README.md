# MEME Launchpad
## Overview
It is a Foundry-based MEME token launchpad where MEMECore manages token creation, bonding-curve trading, vesting, and graduation into PancakeSwap-style liquidity.
Core files:
- MEMECore.sol: the launchpad ledger and rule engine, main lifecycle contract.
- MEMEFactory.sol: deploys new ERC20 tokens with `CREATE2`.
- MEMEToken.sol: launched ERC20 token with transfer restrictions until graduation.
- MEMEHelper.sol: bonding curve math and PancakeSwap v2 liquidity helper.
- MEMEVesting.sol: holds locked creator allocations.

## Architecture
```mermaid
flowchart TD
    User[Creator / Trader]
    Backend[Backend Signer]
    Core[MEMECore<br/>Upgradeable UUPS]
    Factory[MEMEFactory]
    Token[MetaNodeToken<br/>ERC20]
    Helper[MEMEHelper]
    Vesting[MEMEVesting<br/>Upgradeable UUPS]
    DEX[PancakeSwap V2]

    Backend -->|sign create params| User
    User -->|createToken / buy / sell| Core
    Core -->|deployToken| Factory
    Factory -->|CREATE2 deploy| Token
    Core -->|curve math / pair / liquidity| Helper
    Core -->|create schedules| Vesting
    Vesting -->|claim vested tokens| User
    Helper -->|addLiquidityETH| DEX
```
- `MEMECore` is the brain. It stores token state, validates backend signatures, charges fees, initializes bonding curves, handles buys/sells, manages graduation, and controls pause/blacklist states.
- `MEMEFactory` is deliberately small. Only addresses with `DEPLOYER_ROLE`, normally `MEMECore`, can call `deployToken`. It uses `CREATE2`, so token addresses can be predicted before deployment.
- `MetaNodeToken` is the ERC20 that gets deployed per launch. It starts in restricted mode, then controlled mode during bonding-curve trading, then normal mode after graduation. The key transfer modes are defined in `MEMEToken.sol` (line 44).
- `MEMEHelper` contains the constant-product math: k = virtualBNBReserve * virtualTokenReserve. Buying increases virtual BNB reserve and decreases virtual token reserve; selling does the reverse.
- `MEMEVesting` stores schedules by `token -> beneficiary -> scheduleId`. It supports `BURN`, `CLIFF`, and `LINEAR` modes from `IVestingParams.sol` (line 25).
## Bonding Curve
The bonding curve here is a temporary AMM before the token "graduates" to PancakeSwap.

                    Bonding Curve: x * y = k

      Token reserve y
      ^
      |
      |     Start
      |      *
      |       \
      |        \
      |         \
      |          \
      |           \
      |            *  After creator initial buy
      |             \
      |              \
      |               \
      |                *  After public buys
      |
      +------------------------------------------------> BNB reserve x


      x = virtualBNBReserve
      y = virtualTokenReserve
      k = x * y
      price = x / y

      As x increases, y decreases.
      As users buy, price goes up.

- For a buy

Before buy:
```
    x0 = virtualBNBReserve
    y0 = virtualTokenReserve
    k  = x0 * y0
```
User pays BNB: `bnbIn = amount paid into curve`

After buy:
```
    x1 = x0 + bnbIn
    y1 = k / x1 (y1 < y0)
```
Tokens received: `tokensOut = y0 - y1`

- So as users buy more:
```
virtualBNBReserve (x) goes up
virtualTokenReserve (y) goes down
price (x / y) goes up
availableTokens goes down
collectedBNB goes up
```

## Timeline flows
### Token Creation Sequence
```mermaid
sequenceDiagram
    participant Creator
    participant Backend
    participant Core as MEMECore
    participant Factory as MEMEFactory
    participant Token as MetaNodeToken
    participant Helper as MEMEHelper
    participant Vesting as MEMEVesting
    participant Platform

    Creator->>Backend: Submit desired launch params
    Backend-->>Creator: Signature over abi(params), chainId, core address
    Creator->>Core: createToken(data, signature) + BNB
    Core->>Core: Decode params, verify signer, expiry, requestId
    Core->>Core: Calculate creation fee, pre-buy, margin
    Core->>Factory: deployToken(name, symbol, supply, timestamp, nonce)
    Factory-->>Token: CREATE2 deploy, mint full supply to Core
    Core->>Helper: getPairAddress(token)
    Core->>Token: setPair(pair)
    Core->>Core: Store TokenInfo and BondingCurveParams
    Core->>Token: setTransferMode(CONTROLLED)
    Core->>Token: setVestingContract(vesting)
    alt Initial buy with vesting
        Core->>Token: burn BURN allocation, if any
        Core->>Vesting: createVestingSchedules(token, creator, allocations)
        Vesting->>Core: transferFrom vested tokens
        Core->>Creator: transfer immediate remainder
    else Initial buy without vesting
        Core->>Creator: transfer initial buy tokens
    end
    Core->>Platform: send creation/pre-buy fees
    Core-->>Creator: TokenCreated event
```
The main entry point is `MEMECore.createToken (line 385)`. Important checks happen there: signature validity, one-time requestId, sale amount validity, max initial buy 9990 basis points, and payment sufficiency.
One subtle but important design choice: the created token mints the entire supply to `MEMECore`, not the creator. The core contract then releases tokens according to launch rules.

### Offchain Approval for Token Creation
The backend signer is offchain approval authority for `MEMECore.createToken`. Creator's wallet submits the signed payload to `MEMECore`. The contract verifies the request payload was signed by an address that has `SIGNER_ROLE` in `MEMECore`.

So the flow is:
1. `Deploy` script initializes `MEMECore` with tokenomics params and roles (including signer for `MEMECore.createToken`) 
2. `Backend` Signs message using private key.
3. `MEMECore`
    - Recovers signer address.
    - Checks if recovered address have `SIGNER_ROLE`, If yes: request approved; otherwise: revert

This pattern is powerful because the backend can dynamically approve launches by signing **without** storing everything onchain:
```solidity
mapping(address => bool) approved;
```

```mermaid
sequenceDiagram
    participant Admin
    participant Core as MEMECore
    participant Creator
    participant Frontend
    participant Backend as Backend Signer
    participant Factory as MEMEFactory

    Admin->>Core: initialize(..., signer, ...)
    Core->>Core: grant SIGNER_ROLE to signer

    Creator->>Frontend: Fill token launch form
    Frontend->>Frontend: Build CreateTokenParams
    Frontend->>Backend: Send params for approval

    Backend->>Backend: Validate business rules offchain
    Backend->>Backend: ABI encode CreateTokenParams
    Backend->>Backend: hash = keccak256(data, chainId, core)
    Backend->>Backend: Sign hash with SIGNER_PRIVATE_KEY
    Backend-->>Frontend: Return data + signature

    Frontend->>Creator: Ask wallet to submit createToken
    Creator->>Core: createToken(data, signature) + required BNB

    Core->>Core: abi.decode(data)
    Core->>Core: hash = keccak256(data, CHAIN_ID, address(this))
    Core->>Core: recover signer from signature
    Core->>Core: require signer has SIGNER_ROLE
    Core->>Core: check timestamp expiry
    Core->>Core: check requestId unused
    Core->>Core: mark requestId used

    Core->>Factory: deployToken(...)
    Factory-->>Core: token address
    Core-->>Creator: TokenCreated event
```
### Vesting
Real token launches often want mixed rules, for example:
```
Initial buy = 10% of total supply

2% burn forever
3% cliff unlock after 30 days
3% linear unlock over 90 days
2% sent immediately
```
That needs multiple allocations:
```solidity
[
    { amount: 200, mode: BURN,   duration: 0 },
    { amount: 300, mode: CLIFF,  duration: 30 days },
    { amount: 300, mode: LINEAR, duration: 90 days }
]
```

### Buy Sequence
```mermaid
sequenceDiagram
    participant Buyer
    participant Core as MEMECore
    participant Helper as MEMEHelper
    participant Token as MetaNodeToken
    participant Platform

    Buyer->>Core: buy(token, minTokenAmount, deadline) + BNB
    Core->>Core: Ensure token is TRADING and launchTime reached
    Core->>Core: tradingFee = msg.value * feeRate
    Core->>Helper: calculateTokenAmountOut(netBNB, curve)
    Helper-->>Core: tokenAmount
    Core->>Core: Clamp to availableTokens if needed
    Core->>Core: Check slippage
    Core->>Core: Update virtual reserves and collectedBNB
    Core->>Platform: send trading fee
    Core->>Buyer: transfer tokens
    alt availableTokens < MIN_LIQUIDITY
        Core->>Core: status = PENDING_GRADUATION
        Core->>Token: setTransferMode(RESTRICTED)
    end
```
The buy path is `MEMECore.buy (line 566)`. The math lives in `MEMEHelper.calculateTokenAmountOut (line 285)`.

### Sell Sequence
```mermaid
sequenceDiagram
    participant Seller
    participant Core as MEMECore
    participant Helper as MEMEHelper
    participant Token as MetaNodeToken
    participant Platform

    Seller->>Token: approve(Core, tokenAmount)
    Seller->>Core: sell(token, tokenAmount, minBNBAmount, deadline)
    Core->>Core: Ensure token is TRADING and launched
    Core->>Helper: calculateBNBAmountOut(tokenAmount, curve)
    Core->>Core: Deduct trading fee, check slippage and collectedBNB
    Core->>Token: transferFrom seller to Core
    Core->>Core: Update virtual reserves and availableTokens
    Core->>Platform: send trading fee
    Core->>Seller: send net BNB
```
The sell path is `MEMECore.sell (line 669)`.

### Graduation Sequence
```mermaid
sequenceDiagram
    participant Deployer
    participant Core as MEMECore
    participant Token as MetaNodeToken
    participant Helper as MEMEHelper
    participant DEX as PancakeSwap V2
    participant Creator
    participant GraduateFeeReceiver

    Deployer->>Core: graduateToken(token)
    Core->>Core: Read collectedBNB and remaining availableTokens
    Core->>Core: Split platform fee, creator fee, liquidity amounts
    Core->>Token: setTransferMode(NORMAL)
    Core->>Token: approve Helper for liquidity tokens
    Core->>Helper: addLiquidityV2(token, liquidityBNB, liquidityTokens)
    Helper->>DEX: addLiquidityETH, LP to burn/dead recipient
    Core->>Core: status = GRADUATED
    Core->>GraduateFeeReceiver: BNB + token platform fee
    Core->>Creator: BNB + token creator fee
```
Graduation is `MEMECore.graduateToken (line 750)`. Once graduated, token transfers become normal ERC20 transfers and trading moves to the DEX.

### Vesting Claim Sequence
```mermaid
sequenceDiagram
    participant Creator
    participant Vesting as MEMEVesting
    participant Token as MetaNodeToken

    Creator->>Vesting: claim(token, scheduleId)
    Vesting->>Vesting: Load schedule
    Vesting->>Vesting: Calculate claimable amount
    alt BURN
        Vesting-->>Creator: 0 claimable
    else CLIFF before end
        Vesting-->>Creator: 0 claimable
    else LINEAR or CLIFF matured
        Vesting->>Vesting: Update claimedAmount and locked total
        Vesting->>Token: transfer claimable tokens
        Vesting-->>Creator: TokensClaimed event
    end
```
The vesting calculation is in `MEMEVesting.sol (line 349)`. LINEAR uses elapsed time over total duration; CLIFF releases everything only after endTime; BURN never becomes claimable.
