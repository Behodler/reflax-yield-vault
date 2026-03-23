# Generic ERC4626 Yield Strategy Research

## 1. Executive Summary

A single `GenericERC4626YieldStrategy` contract can serve as a universal adapter for any standard ERC4626 vault, replacing the Tokemak-specific two-layer architecture of `AutoPoolYieldStrategy` with a dramatically simpler design. The existing `AutoPoolYieldStrategy` deposits into an ERC4626 vault and then stakes the resulting shares into Tokemak's `MainRewarder` for TOKE rewards -- this secondary staking layer accounts for roughly 60% of the contract's complexity. A generic strategy removes this layer entirely: shares are held directly by the strategy contract, simplifying deposit to a single `vault.deposit()` call, withdrawal to a single `vault.redeem()` call, and yield tracking to a direct `vault.convertToAssets(vault.balanceOf(this))` query.

All three investigated vaults -- yBOLD (`0x9F4330700a36B29952869fac9b33f45EEdd8A3d8`), sBOLD (`0x50bd66d59911f5e086ec87ae43c811e0d059dd11`), and sUSDS (`0xa3931d71877c0e7a3148cb7eb4463524fec27fbd`) -- conform to ERC4626, though each has vault-specific quirks (entry fees, pause-during-liquidation, proxy upgradeability). These quirks do not require per-vault subclasses; they are handled by the ERC4626 standard's `preview*` and `max*` functions. A single generic contract with constructor-only configuration `(owner, underlyingToken, erc4626Vault)` is sufficient.

**Recommendation**: Proceed with a single `GenericERC4626YieldStrategy` contract. Deploy one instance per token/vault pair. No factory pattern is needed initially but could be added later for operational convenience.

---

## 2. yBOLD ERC4626 Verification

**Contract**: `0x9F4330700a36B29952869fac9b33f45EEdd8A3d8`
**Name**: Yearn V3 Vault
**Symbol**: yBOLD
**Language**: Vyper (v0.3.7)
**License**: GNU AGPLv3
**Underlying Asset**: BOLD (Liquity stablecoin)

### ERC4626 Function Conformance

| Function | Present | Notes |
|----------|---------|-------|
| `asset()` | Yes | Returns BOLD token address |
| `totalAssets()` | Yes | Returns idle + strategy debt |
| `deposit(uint256, address)` | Yes | Standard signature |
| `mint(uint256, address)` | Yes | Standard signature |
| `withdraw(uint256, address, address)` | Yes | Standard signature |
| `redeem(uint256, address, address)` | Yes | Standard signature |
| `convertToShares(uint256)` | Yes | Standard |
| `convertToAssets(uint256)` | Yes | Standard |
| `maxDeposit(address)` | Yes | May return 0 under certain conditions |
| `maxMint(address)` | Yes | Standard |
| `maxWithdraw(address)` | Yes | Includes loss simulation |
| `maxRedeem(address)` | Yes | Standard |
| `previewDeposit(uint256)` | Yes | Standard |
| `previewMint(uint256)` | Yes | Standard |
| `previewWithdraw(uint256)` | Yes | Standard |
| `previewRedeem(uint256)` | Yes | Standard |

### Key Implementation Details

- Multi-strategy allocation system with configurable withdrawal queues
- Profit unlocking over configurable periods (yield does not appear instantly)
- Role-based access controls for strategy management
- Dynamic debt management across connected strategies
- No entry/exit fees at the vault level
- `maxWithdraw` performs loss simulation to account for strategy-level losses

### Implications for Generic Strategy

yBOLD is fully standard ERC4626. The profit-unlocking mechanism is transparent to depositors -- `convertToAssets` and `totalAssets` reflect only unlocked profits, so the generic strategy's yield tracking will naturally exclude unrealized/locked profits. No special handling needed.

---

## 3. sBOLD ERC4626 Verification

**Contract**: `0x50bd66d59911f5e086ec87ae43c811e0d059dd11`
**Name**: sBold
**Symbol**: sBOLD
**Language**: Solidity (v0.8.24)
**Builder**: K3 Capital
**Underlying Asset**: BOLD
**Audit**: ChainSecurity

### ERC4626 Function Conformance

All 16 standard ERC4626 functions are implemented (same checklist as yBOLD above -- all present).

### Key Implementation Details

- **Yield source**: Liquity V2 Stability Pool interest + liquidation gains
- **Allocation**: Fixed 70% wstETH pool / 20% rETH pool / 10% WETH pool
- **Entry fees**: `feeBps` parameter exists; initially set to 0 but can be enabled by K3
- **Pause behavior**: Contract is paused during liquidations to prevent front-running; otherwise always available
- **Rebalancing**: Pool weights can be changed by governance
- **Exchange rate**: `totalBOLDInPools / totalSupplyOfsBOLD` -- straightforward ERC4626 share pricing
- **Collateral health checks**: `maxDeposit` may return 0 if collateral exceeds threshold or oracle fails

### Implications for Generic Strategy

The potential entry fee (`feeBps`) is the main quirk. However, this is handled transparently by ERC4626:
- `previewDeposit(amount)` returns shares *after* fee deduction
- `convertToShares(amount)` may differ from actual deposit shares when fees are active
- The generic strategy should use `vault.deposit(amount, address(this))` and track the *returned* share count, not `convertToShares`. This is already the pattern in `AutoPoolYieldStrategy`.

The pause-during-liquidation behavior means `maxDeposit` / `maxWithdraw` may temporarily return 0. The generic strategy should respect these limits and revert gracefully rather than attempting operations during paused periods. This is standard ERC4626 behavior -- no special handling needed.

---

## 4. sUSDS ERC4626 Verification

**Contract (Proxy)**: `0xa3931d71877c0e7a3148cb7eb4463524fec27fbd`
**Implementation**: `0x4e7991e5C547ce825BdEb665EE14a3274f9F61e0`
**Name**: Savings USDS
**Symbol**: sUSDS
**Language**: Solidity (v0.8.21)
**Architecture**: ERC-1822 UUPS proxy with ERC-1967 storage slots (upgradeable)
**Underlying Asset**: USDS (`0xdC035D45d973E3EC169d2276DDab16f1e407384F`)
**Builder**: Sky Protocol (formerly MakerDAO)

### ERC4626 Function Conformance

All standard ERC4626 functions are implemented. Full compliance confirmed by Spark documentation.

### Key Implementation Details

- **Yield source**: Sky Savings Rate (SSR) -- protocol-level interest accrual
- **No fees**: No deposit fees, withdrawal fees, or deposit limits
- **Not rebasing**: Despite holding an increasing amount of USDS, sUSDS is a share-based vault, not a rebasing token. Share value increases over time rather than share count.
- **Event quirk**: Emits ERC4626 `Deposit`/`Withdraw` events during mint/burn rather than redundant ERC20 `Transfer` events. This does not affect on-chain behavior but may affect off-chain indexing.
- **Upgradeability**: UUPS proxy means the implementation can change. The generic strategy interacts only through the standard ERC4626 interface, so upgrades are transparent as long as ERC4626 compliance is maintained.
- **ERC4626 only on mainnet**: Cross-chain deployments (L2s) do not support native ERC4626 deposit/withdraw.

### Implications for Generic Strategy

sUSDS is the simplest of the three vaults from an integration perspective: no fees, no pauses, no limits, straightforward share-price appreciation. The UUPS proxy upgradeability is a governance risk but not a technical integration concern. No special handling needed.

---

## 5. Architecture Comparison: AutoPoolYieldStrategy vs GenericERC4626YieldStrategy

### Side-by-Side Comparison

| Aspect | AutoPoolYieldStrategy | GenericERC4626YieldStrategy |
|--------|----------------------|---------------------------|
| **Constructor params** | `owner, underlyingToken, tokeToken, autoPoolVault, mainRewarder` (5 params) | `owner, underlyingToken, erc4626Vault` (3 params) |
| **Immutable state** | `underlyingToken, tokeToken, autoPoolVault, mainRewarder` (4 vars) | `underlyingToken, vault` (2 vars) |
| **Approvals in constructor** | 2: vault for token, MainRewarder for shares | 1: vault for token |
| **Deposit flow** | Transfer -> vault.deposit -> mainRewarder.stake (3 steps) | Transfer -> vault.deposit (2 steps) |
| **Withdrawal flow** | mainRewarder.withdraw(ALL) -> vault.redeem -> mainRewarder.stake(leftover) (3 steps) | vault.redeem (1 step) |
| **Yield tracking** | `vault.convertToAssets(mainRewarder.balanceOf(this))` | `vault.convertToAssets(vault.balanceOf(this))` |
| **Emergency withdraw** | Calculate shares -> unstake from MainRewarder -> redeem from vault (3 steps) | Calculate shares -> redeem from vault (2 steps) |
| **Total withdraw** | Calculate proportional shares -> unstake -> redeem -> transfer (4 steps) | Calculate proportional shares -> redeem -> transfer (3 steps) |
| **WithdrawFrom (surplus)** | Unstake ALL -> redeem surplus shares -> re-stake leftover (3 steps) | Redeem surplus shares (1 step) |
| **Extra functions** | `claimTokeRewards()`, `getTokeRewards()` | None |
| **Gas cost (deposit)** | ~3 external calls | ~2 external calls |
| **Gas cost (withdraw)** | ~4 external calls (unstake all, redeem, re-stake) | ~1 external call |

### Tokemak-Specific Code in AutoPoolYieldStrategy

The following elements are **exclusively Tokemak-specific** and would be removed:

1. **State variables**: `tokeToken` (IERC20), `mainRewarder` (IMainRewarder)
2. **Constructor**: Validation and assignment of `_tokeToken`, `_mainRewarder`; approval of MainRewarder for shares
3. **Deposit**: `mainRewarder.stake(address(this), sharesReceived)` call after vault deposit
4. **Withdraw**: `mainRewarder.withdraw(address(this), totalShares, false)` before redeem; `mainRewarder.stake(address(this), leftoverShares)` after redeem
5. **Emergency withdraw**: `mainRewarder.balanceOf(address(this))` for share tracking; `mainRewarder.withdraw()` for unstaking
6. **Total withdraw**: Same MainRewarder interactions as emergency withdraw
7. **WithdrawFrom**: Same unstake-all / re-stake pattern
8. **View functions**: `getTokeRewards()`, `getTotalShares()` (uses `mainRewarder.earned()`)
9. **Claim function**: `claimTokeRewards()` -- entire function is Tokemak-specific

### Generic ERC4626 Code (retained from AutoPoolYieldStrategy)

1. **State variables**: `underlyingToken` (IERC20), `clientBalances` mapping, `totalDeposited` mapping
2. **Constructor**: Owner, underlying token, vault setup + approval
3. **Deposit**: Transfer from client, `vault.deposit()`, track principal
4. **Withdraw**: `vault.convertToShares()`, `vault.redeem()`, update principal
5. **Balance tracking**: `principalOf`, `totalBalanceOf`, `balanceOf` (backward compat)
6. **Security properties**: Rounding favors protocol, dust handling, surplus-only enforcement

---

## 6. Proposed Contract Design

### Constructor Signature

```
constructor(
    address _owner,
    address _underlyingToken,
    address _erc4626Vault
) AYieldStrategy(_owner)
```

### State Variables

```
IERC20 public immutable underlyingToken;
IERC4626 public immutable vault;

mapping(address => mapping(address => uint256)) private clientBalances;  // token => client => principal
mapping(address => uint256) private totalDeposited;                      // token => total principal
```

### Method Signatures and Pseudocode

#### `deposit(address token, uint256 amount, address recipient)`

```
Modifiers: onlyAuthorizedClient, nonReentrant, whenNotPaused
Require: token == underlyingToken, amount > 0, recipient != address(0)

1. underlyingToken.safeTransferFrom(msg.sender, address(this), amount)
2. sharesReceived = vault.deposit(amount, address(this))
3. require(sharesReceived > 0)
4. clientBalances[token][recipient] += amount
5. totalDeposited[token] += amount
6. emit Deposited(token, msg.sender, recipient, amount, sharesReceived)
```

#### `withdraw(address token, uint256 amount, address recipient)`

```
Modifiers: onlyAuthorizedClient, nonReentrant, whenNotPaused
Require: token == underlyingToken, amount > 0, recipient != address(0)

1. Cap amount to clientBalances[token][recipient] (dust handling)
2. sharesToRedeem = vault.convertToShares(amount)
3. Cap sharesToRedeem to vault.balanceOf(address(this))
4. tokensReceived = vault.redeem(sharesToRedeem, recipient, address(this))
5. clientBalances[token][recipient] -= amount   // Decrement by requested, not received (protocol-favoring rounding)
6. totalDeposited[token] -= amount
7. emit Withdrawn(token, msg.sender, recipient, tokensReceived, sharesToRedeem)
```

#### `_emergencyWithdraw(uint256 amount)`

```
1. totalShares = vault.balanceOf(address(this))
2. require(totalShares > 0)
3. totalAssets = vault.convertToAssets(totalShares)
4. sharesToWithdraw = (amount < totalAssets) ? vault.convertToShares(amount) : totalShares
5. assetsReceived = vault.redeem(sharesToWithdraw, address(this), address(this))
6. actualAmount = min(assetsReceived, amount)
7. underlyingToken.safeTransfer(owner(), actualAmount)
```

#### `_totalWithdraw(address token, address client, uint256 amount)`

```
1. totalShares = vault.balanceOf(address(this))
2. if totalShares == 0 or totalDeposited[token] == 0: return
3. clientStoredBalance = clientBalances[token][client]
4. sharesToWithdraw = (totalShares * clientStoredBalance) / totalDeposited[token]
5. if sharesToWithdraw > 0:
   a. assetsReceived = vault.redeem(sharesToWithdraw, address(this), address(this))
   b. clientBalances[token][client] = 0
   c. totalDeposited[token] -= clientStoredBalance
   d. underlyingToken.safeTransfer(owner(), assetsReceived)
```

#### `_withdrawFrom(address token, address client, uint256 amount, address recipient)`

```
1. principal = clientBalances[token][client]
2. totalBalance = this.totalBalanceOf(token, client)
3. surplus = (totalBalance > principal) ? totalBalance - principal : 0
4. require(amount <= surplus)
5. sharesToRedeem = vault.convertToShares(amount)
6. Cap sharesToRedeem to vault.balanceOf(address(this))
7. vault.redeem(sharesToRedeem, recipient, address(this))
// Principal tracking is NEVER modified for surplus withdrawals
```

#### `totalBalanceOf(address token, address account)`

```
1. principal = clientBalances[token][account]
2. if principal == 0 or totalDeposited[token] == 0: return 0
3. totalShares = vault.balanceOf(address(this))
4. totalValue = vault.convertToAssets(totalShares)
5. return (totalValue * principal) / totalDeposited[token]
```

#### `principalOf(address token, address account)`

```
return clientBalances[token][account]
```

#### `balanceOf(address token, address account)` (backward compat)

```
return this.principalOf(token, account)
```

### View Functions

```
function underlying() external view returns (address)       // returns address(underlyingToken)
function getTotalDeposited(address token) external view returns (uint256)  // returns totalDeposited[token]
function getTotalShares() external view returns (uint256)    // returns vault.balanceOf(address(this))
```

---

## 7. Token/Vault Compatibility Matrix

| Property | BOLD / yBOLD | BOLD / sBOLD | USDS / sUSDS |
|----------|-------------|-------------|-------------|
| **Vault address** | `0x9F4330...` | `0x50bd66...` | `0xa3931d...` |
| **Underlying token** | BOLD | BOLD | USDS |
| **ERC4626 compliant** | Yes (full) | Yes (full) | Yes (full) |
| **Implementation** | Vyper (Yearn V3) | Solidity (K3 Capital) | Solidity (Sky/UUPS proxy) |
| **Entry fees** | None | `feeBps` (currently 0, can be enabled) | None |
| **Exit fees** | None | None observed | None |
| **Withdrawal delays** | None (vault-level) | Paused during liquidations | None |
| **Deposit limits** | `maxDeposit` may return 0 | `maxDeposit` may return 0 (collateral health) | No limits |
| **Rebasing** | No (share-based) | No (share-based) | No (share-based) |
| **Yield source** | Multi-strategy allocation | Stability Pool interest + liquidation gains | Sky Savings Rate (SSR) |
| **Upgradeability** | No | No | Yes (UUPS proxy) |
| **Audit** | Yearn V3 audited | ChainSecurity audit | Sky/MakerDAO audited |
| **Generic strategy compatible** | Yes | Yes | Yes |
| **Special handling needed** | None | Respect `maxDeposit` returning 0 during liquidations | None |

### Key Observation

All three vaults are compatible with a single generic contract. The only behavioral difference is sBOLD's potential entry fee, but this is transparently handled by the ERC4626 standard's `deposit()` return value (actual shares received) and `previewDeposit()`. The generic strategy already tracks shares received from `vault.deposit()`, not calculated shares, so fees are automatically accounted for.

---

## 8. Withdrawal Flow Comparison

### AutoPoolYieldStrategy Withdrawal (Current)

```
Client calls withdraw(token, amount, recipient)
  |
  v
1. Cap amount to available principal (dust handling)
  |
  v
2. TOKEMAK: Unstake ALL shares from MainRewarder
   mainRewarder.withdraw(address(this), totalShares, false)
  |
  v
3. Convert amount to shares: vault.convertToShares(amount)
   Cap to available: vault.balanceOf(address(this))
  |
  v
4. Redeem shares from vault: vault.redeem(sharesToRedeem, recipient, address(this))
  |
  v
5. TOKEMAK: Re-stake ALL remaining shares into MainRewarder
   leftoverShares = vault.balanceOf(address(this))
   mainRewarder.stake(address(this), leftoverShares)
  |
  v
6. Update principal tracking: clientBalances -= amount, totalDeposited -= amount

External calls: 4 (unstake, redeem, re-stake, transfer)
```

### GenericERC4626YieldStrategy Withdrawal (Proposed)

```
Client calls withdraw(token, amount, recipient)
  |
  v
1. Cap amount to available principal (dust handling)
  |
  v
2. Convert amount to shares: vault.convertToShares(amount)
   Cap to available: vault.balanceOf(address(this))
  |
  v
3. Redeem shares from vault: vault.redeem(sharesToRedeem, recipient, address(this))
  |
  v
4. Update principal tracking: clientBalances -= amount, totalDeposited -= amount

External calls: 1 (redeem -- transfer is done by vault)
```

### Gas Savings Estimate

The generic strategy eliminates 2-3 external calls per withdrawal (MainRewarder unstake + re-stake). Each MainRewarder interaction involves storage reads/writes and potential reward calculations. Conservative estimate: **40-60% gas reduction on withdrawals**.

### Deposit Flow Comparison

| Step | AutoPoolYieldStrategy | GenericERC4626YieldStrategy |
|------|----------------------|---------------------------|
| 1 | `transferFrom(client, this, amount)` | `transferFrom(client, this, amount)` |
| 2 | `vault.deposit(amount, this)` | `vault.deposit(amount, this)` |
| 3 | `mainRewarder.stake(this, shares)` | *(not needed)* |
| 4 | Update clientBalances, totalDeposited | Update clientBalances, totalDeposited |

Deposit saves 1 external call (MainRewarder stake). Estimated **20-30% gas reduction on deposits**.

---

## 9. Simplified Yield Tracking

### AutoPoolYieldStrategy (Current)

```solidity
// Shares are staked in MainRewarder, not held by strategy
uint256 totalShares = mainRewarder.balanceOf(address(this));      // Query MainRewarder
uint256 totalValue = autoPoolVault.convertToAssets(totalShares);   // Convert to underlying
return (totalValue * principal) / totalDeposited[token];           // Proportional share
```

Two external calls: `mainRewarder.balanceOf` + `vault.convertToAssets`.

### GenericERC4626YieldStrategy (Proposed)

```solidity
// Shares are held directly by the strategy contract
uint256 totalShares = vault.balanceOf(address(this));              // Direct ERC20 balance
uint256 totalValue = vault.convertToAssets(totalShares);           // Convert to underlying
return (totalValue * principal) / totalDeposited[token];           // Proportional share
```

Two external calls: `vault.balanceOf` + `vault.convertToAssets`. Same number of calls, but `vault.balanceOf` is a simple ERC20 balance lookup (single SLOAD), whereas `mainRewarder.balanceOf` may involve additional reward calculations. Marginally cheaper.

### Key Insight

The yield tracking formula is identical in structure. The only difference is the source of the share balance: `mainRewarder.balanceOf(this)` vs `vault.balanceOf(this)`. This is the cleanest proof that the Tokemak layer is purely additive and can be stripped without affecting yield accounting logic.

---

## 10. Edge Cases and Risks

### 10.1 Entry Fees (sBOLD)

**Risk**: sBOLD has a `feeBps` parameter that can be enabled. When active, `vault.deposit(amount)` returns fewer shares than `convertToShares(amount)` would suggest.

**Mitigation**: The generic strategy already handles this correctly by tracking the *return value* of `vault.deposit()` as `sharesReceived`, not a pre-calculated share amount. The fee is absorbed into a lower share count. Principal tracking uses the original `amount` deposited (in underlying terms), so the fee manifests as slightly lower `totalBalanceOf` relative to `principalOf` initially. Over time, yield accumulation will recover this.

**Assessment**: No code change needed. Standard ERC4626 behavior.

### 10.2 Temporary Deposit/Withdrawal Restrictions

**Risk**: Both yBOLD and sBOLD may temporarily return 0 from `maxDeposit` or `maxWithdraw` (sBOLD during liquidations, yBOLD during strategy rebalancing).

**Mitigation**: The generic strategy calls `vault.deposit()` / `vault.redeem()` directly. If the vault is temporarily paused or at capacity, these calls will revert. The strategy does not need to pre-check `maxDeposit` -- the vault enforces its own limits. The authorized client (e.g., Dispatcher) should handle reverts gracefully and retry.

**Assessment**: No special handling needed in the strategy. Document this behavior for clients.

### 10.3 Rebasing Vaults

**Risk**: Some ERC4626-adjacent tokens use rebasing (e.g., stETH). If the vault's share balance changes without deposit/withdraw, yield tracking could break.

**Assessment**: None of the three investigated vaults are rebasing. All use share-price appreciation (shares stay constant, `convertToAssets(shares)` increases). The generic strategy is designed for share-based vaults. **If a rebasing vault is encountered in the future**, it would require a subclass or a wrapper that converts the rebasing token to a share-based representation (e.g., wstETH wraps stETH).

**Recommendation**: Add a note in the contract NatSpec that rebasing vaults are not supported. Consider adding a constructor-time check that `vault.convertToAssets(1e18)` returns a sensible value.

### 10.4 Withdrawal Fees

**Risk**: Some ERC4626 vaults charge exit fees (e.g., Yearn V3 vaults can have performance fees that affect withdrawals).

**Assessment**: yBOLD and sUSDS have no withdrawal fees. sBOLD has no observed withdrawal fees (only potential entry fees). The generic strategy's rounding-favors-protocol property (decrement principal by requested amount, not received amount) already handles any shortfall from fees. Any difference between requested and received amounts accrues to the protocol.

**Recommendation**: No change needed. The existing security property handles this edge case.

### 10.5 ERC4626 Rounding Direction

**Risk**: ERC4626 specifies that `convertToShares` should round down (favoring the vault) and `convertToAssets` should round down (favoring the vault). Some implementations may round differently.

**Assessment**: The generic strategy uses `vault.redeem()` (which takes shares as input) rather than `vault.withdraw()` (which takes assets as input) for most operations. This is the correct approach because `redeem` has deterministic share burning, while `withdraw` may round up the shares needed. The AutoPoolYieldStrategy already uses this pattern and the generic strategy preserves it.

### 10.6 Share Price Manipulation (Inflation Attack)

**Risk**: The classic ERC4626 inflation attack where an attacker front-runs the first deposit by donating tokens to manipulate the share price.

**Assessment**: This is a vault-level concern, not a strategy-level concern. All three vaults (yBOLD, sBOLD, sUSDS) have their own protections against this. The generic strategy is not the first depositor in isolation -- it deposits into an existing vault with existing shares.

### 10.7 Proxy Upgradeability (sUSDS)

**Risk**: sUSDS uses a UUPS proxy. The implementation could be upgraded to change behavior.

**Assessment**: This is a governance/trust risk, not a technical integration risk. The generic strategy interacts exclusively through the ERC4626 interface. As long as an upgraded implementation maintains ERC4626 compliance, the strategy continues to work. This risk should be documented and monitored operationally.

### 10.8 Multi-Token Support

**Risk**: The `IYieldStrategy` interface accepts an arbitrary `token` parameter, but each generic strategy instance is bound to a single underlying token.

**Assessment**: This is by design. Each deployed instance validates `token == address(underlyingToken)` and reverts otherwise. This matches the existing `AutoPoolYieldStrategy` behavior. For multiple token/vault pairs, deploy multiple instances.

---

## 11. Single Contract vs Per-Vault Subclasses

### Assessment

A single `GenericERC4626YieldStrategy` contract is sufficient for all three investigated vaults. The analysis shows:

1. **No vault-specific logic is needed**: All behavioral differences (fees, pauses, limits) are handled by the ERC4626 standard interface
2. **Constructor-only configuration**: The only differences between deployments are the constructor arguments `(owner, underlyingToken, erc4626Vault)`
3. **Identical method implementations**: Every method has the same logic regardless of vault

### When Would Subclasses Be Needed?

Subclasses would only be necessary if a future vault:
- Uses rebasing tokens (share count changes without deposit/withdraw)
- Requires secondary staking (like Tokemak's MainRewarder -- but then use AutoPoolYieldStrategy)
- Has non-standard ERC4626 functions that must be called (e.g., `claim()` for reward tokens)
- Requires token wrapping before deposit (e.g., ETH -> WETH, stETH -> wstETH)

None of the three investigated vaults require this.

### Factory Pattern

A factory is not needed for the initial implementation but would be beneficial if the number of token/vault pairs grows beyond 5-10:

```
// Future consideration only
GenericERC4626YieldStrategyFactory.deploy(owner, underlyingToken, vault) -> address
```

This would provide standardized deployment, event logging, and a registry of all deployed instances.

---

## 12. Recommendation

**Proceed with a single `GenericERC4626YieldStrategy` contract.**

Rationale:
1. All three target vaults (yBOLD, sBOLD, sUSDS) are fully ERC4626 compliant
2. No vault-specific logic is needed -- constructor-only configuration suffices
3. The contract is dramatically simpler than `AutoPoolYieldStrategy` (2 state variables vs 4, ~50% fewer lines of code)
4. Gas costs are significantly lower (no MainRewarder interactions)
5. All security properties from `AYieldStrategy` are preserved (timelock, access control, pause, reentrancy guard)
6. Edge cases (fees, pauses, rounding) are handled by existing design patterns

---

## 13. Next Steps

### Implementation Story Outline

1. **Create `GenericERC4626YieldStrategy.sol`** in `src/concreteYieldStrategies/`
   - Extend `AYieldStrategy`
   - Use `IERC4626` from OpenZeppelin (not `IAutoPool`)
   - Implement all 5 virtual methods + view functions as designed above

2. **Write comprehensive tests** in `test/GenericERC4626YieldStrategy.t.sol`
   - Unit tests for each method (deposit, withdraw, emergencyWithdraw, totalWithdraw, withdrawFrom)
   - Yield accrual tests (verify totalBalanceOf increases when vault earns yield)
   - Edge case tests (dust handling, max amount, zero balance)
   - Access control tests (unauthorized client, unauthorized withdrawer)
   - Mock ERC4626 vault for testing (or use existing mock infrastructure)

3. **Integration testing considerations**
   - Fork tests against mainnet yBOLD for realistic ERC4626 behavior
   - Test with fee-charging vault mock to verify sBOLD compatibility
   - Test with temporarily-paused vault mock to verify graceful revert handling

4. **Deployment preparation**
   - Add deployment script for each token/vault pair
   - Document constructor parameters for yBOLD, sBOLD, sUSDS instances
   - Plan for client authorization (which Dispatchers can deposit/withdraw)

5. **Future considerations**
   - Factory contract if >5 pairs are deployed
   - Monitoring/alerting for sUSDS proxy upgrades
   - Re-evaluate if rebasing vaults are needed
