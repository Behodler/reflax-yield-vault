# UniswapV4 Accounting Bug Fix Plan

## Executive Summary

The `UniV4StableYieldStrategy` contract has critical accounting bugs that prevent proper yield tracking and create a vulnerability where anyone can steal accumulated fees. This document outlines the problems and proposes a comprehensive fix.

---

## Problem Statement

### Bug 1: `collectYield()` Has No Access Control

**Location:** `UniV4StableYieldStrategy.sol:202-233`

```solidity
function collectYield() external nonReentrant whenNotPaused returns (uint256 totalYieldInDepositToken) {
    (uint256 fees0, uint256 fees1) = _collectFees();
    // ...
    depositToken.safeTransfer(msg.sender, totalYieldInDepositToken); // Sends to caller!
}
```

**Impact:** Anyone can call this function and steal all accumulated fees. The function transfers collected yield directly to `msg.sender` without any access control.

### Bug 2: `_estimateTotalValue()` Ignores Pending Fees

**Location:** `UniV4StableYieldStrategy.sol:669-686`

```solidity
function _estimateTotalValue() internal view returns (uint256 totalValue) {
    if (liquidityPosition == 0) return 0;
    uint256 liquidityIn18 = uint256(liquidityPosition);
    uint256 estimatedValue = liquidityIn18 * 2; // Only counts liquidity, NOT fees
    // ...
}
```

**Impact:** `totalBalanceOf()` returns approximately the same value as `principalOf()`, making it impossible to detect accumulated yield.

### Bug 3: `pendingYield()` Is a Stub

**Location:** `UniV4StableYieldStrategy.sol:240-251`

```solidity
function pendingYield() external view returns (uint256 depositTokenFees, uint256 pairedTokenFees) {
    // ...
    // Note: In a real implementation, this would query the actual pending fees from V4
    return (0, 0); // Always returns zero!
}
```

**Impact:** No way to query pending fees without collecting them.

### Bug 4: `liquidityPosition` Does Not Include Fees

The state variable `liquidityPosition` only tracks liquidity units, not accrued fees. In Uniswap V4, fees accrue separately and are tracked via fee growth accumulators.

---

## StableYieldAccumulator Expectations

The `stableYieldAccumulator` (downstream consumer) expects the following workflow:

```
1. Query totalBalanceOf(token, client) → Get total value including yield
2. Query principalOf(token, client)    → Get original deposit amount
3. Calculate surplus = totalBalance - principal
4. If surplus > 0, call withdrawFrom(token, client, surplus, recipient)
```

### Current Broken Behavior

```
1. totalBalanceOf() → Returns ~principal (fees not counted)
2. principalOf()    → Returns principal
3. surplus = ~0     → No yield detected
4. withdrawFrom() never called → Fees remain uncollected
5. Anyone calls collectYield() → Steals all fees
```

### Expected Fixed Behavior

```
1. totalBalanceOf() → Returns principal + pending fees (properly calculated)
2. principalOf()    → Returns principal
3. surplus > 0      → Yield correctly detected
4. withdrawFrom() called → Collects and transfers yield to authorized recipient
```

---

## Proposed Solution

### Overview

Implement proper Uniswap V4 fee accounting by:
1. Extending `IPoolManager` interface with fee growth getters
2. Implementing proper pending fee calculation in `pendingYield()`
3. Updating `_estimateTotalValue()` to include pending fees
4. Fixing `collectYield()` access control

### Uniswap V4 Fee Calculation Background

In Uniswap V4, fees are not stored directly per position. Instead, they're calculated using fee growth accumulators:

```
pendingFees = liquidity × (feeGrowthInsideCurrent - feeGrowthInsideLast) / 2^128
```

Where `feeGrowthInsideCurrent` is derived from:
- `feeGrowthGlobal` - Total fee growth for the entire pool
- `feeGrowthOutsideLower` - Fee growth outside the lower tick
- `feeGrowthOutsideUpper` - Fee growth outside the upper tick
- Current tick position relative to the position's tick range

---

## Implementation Plan

### Phase 1: Extend IPoolManager Interface

**File:** `src/imports/IPoolManager.sol`

Add the following view functions:

```solidity
/**
 * @notice Get global fee growth for a pool
 * @param poolId The pool ID
 * @return feeGrowthGlobal0X128 Global fee growth for token0
 * @return feeGrowthGlobal1X128 Global fee growth for token1
 */
function getFeeGrowthGlobal(PoolId poolId)
    external
    view
    returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128);

/**
 * @notice Get fee growth outside a tick
 * @param poolId The pool ID
 * @param tick The tick to query
 * @return feeGrowthOutside0X128 Fee growth outside for token0
 * @return feeGrowthOutside1X128 Fee growth outside for token1
 */
function getTickFeeGrowthOutside(PoolId poolId, int24 tick)
    external
    view
    returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128);
```

**Justification:** These are standard V4 PoolManager view functions needed to calculate pending fees without modifying state.

### Phase 2: Implement Pending Fee Calculation

**File:** `src/concreteYieldStrategies/UniV4StableYieldStrategy.sol`

#### 2.1 Add Internal Fee Calculation Helper

```solidity
/**
 * @notice Calculate pending fees for the position
 * @return fees0 Pending fees in token0
 * @return fees1 Pending fees in token1
 */
function _calculatePendingFees() internal view returns (uint256 fees0, uint256 fees1) {
    if (liquidityPosition == 0) return (0, 0);

    // Get position's last fee growth snapshot
    (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) =
        poolManager.getPosition(poolId, address(this), tickLower, tickUpper, POSITION_SALT);

    // Calculate current fee growth inside the tick range
    (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside();

    // Calculate pending fees
    // fees = liquidity * (feeGrowthInsideCurrent - feeGrowthInsideLast) / 2^128
    fees0 = uint256(liquidity) * (feeGrowthInside0X128 - feeGrowthInside0LastX128) / (1 << 128);
    fees1 = uint256(liquidity) * (feeGrowthInside1X128 - feeGrowthInside1LastX128) / (1 << 128);
}

/**
 * @notice Calculate current fee growth inside the position's tick range
 * @return feeGrowthInside0X128 Current fee growth inside for token0
 * @return feeGrowthInside1X128 Current fee growth inside for token1
 */
function _getFeeGrowthInside() internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
    // Get global fee growth
    (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = poolManager.getFeeGrowthGlobal(poolId);

    // Get fee growth outside lower tick
    (uint256 feeGrowthOutsideLower0X128, uint256 feeGrowthOutsideLower1X128) =
        poolManager.getTickFeeGrowthOutside(poolId, tickLower);

    // Get fee growth outside upper tick
    (uint256 feeGrowthOutsideUpper0X128, uint256 feeGrowthOutsideUpper1X128) =
        poolManager.getTickFeeGrowthOutside(poolId, tickUpper);

    // Get current tick
    int24 currentTick = poolManager.getCurrentTick(poolId);

    // Calculate fee growth inside based on current tick position
    // This follows Uniswap V3/V4 fee accounting logic
    uint256 feeGrowthBelow0X128;
    uint256 feeGrowthBelow1X128;
    uint256 feeGrowthAbove0X128;
    uint256 feeGrowthAbove1X128;

    if (currentTick >= tickLower) {
        feeGrowthBelow0X128 = feeGrowthOutsideLower0X128;
        feeGrowthBelow1X128 = feeGrowthOutsideLower1X128;
    } else {
        feeGrowthBelow0X128 = feeGrowthGlobal0X128 - feeGrowthOutsideLower0X128;
        feeGrowthBelow1X128 = feeGrowthGlobal1X128 - feeGrowthOutsideLower1X128;
    }

    if (currentTick < tickUpper) {
        feeGrowthAbove0X128 = feeGrowthOutsideUpper0X128;
        feeGrowthAbove1X128 = feeGrowthOutsideUpper1X128;
    } else {
        feeGrowthAbove0X128 = feeGrowthGlobal0X128 - feeGrowthOutsideUpper0X128;
        feeGrowthAbove1X128 = feeGrowthGlobal1X128 - feeGrowthOutsideUpper1X128;
    }

    feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
    feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
}
```

**Justification:** This is the standard Uniswap fee calculation algorithm used in V3/V4. It correctly handles the three cases: current tick below range, within range, or above range.

#### 2.2 Fix `pendingYield()`

Replace the stub implementation:

```solidity
function pendingYield() external view returns (uint256 depositTokenFees, uint256 pairedTokenFees) {
    (uint256 fees0, uint256 fees1) = _calculatePendingFees();

    if (address(depositToken) == poolKey.currency0) {
        depositTokenFees = fees0;
        pairedTokenFees = fees1;
    } else {
        depositTokenFees = fees1;
        pairedTokenFees = fees0;
    }
}
```

**Justification:** Properly returns pending fees without modifying state, allowing callers to query yield before deciding to collect.

### Phase 3: Update `_estimateTotalValue()`

```solidity
function _estimateTotalValue() internal view returns (uint256 totalValue) {
    if (liquidityPosition == 0) return 0;

    // Calculate liquidity value (existing logic)
    uint256 liquidityIn18 = uint256(liquidityPosition);
    uint256 liquidityValue = liquidityIn18 * 2;

    // Add pending fees
    (uint256 fees0, uint256 fees1) = _calculatePendingFees();

    // Convert fees to deposit token terms
    uint256 depositFees;
    uint256 pairedFees;
    if (address(depositToken) == poolKey.currency0) {
        depositFees = fees0;
        pairedFees = fees1;
    } else {
        depositFees = fees1;
        pairedFees = fees0;
    }

    // Normalize paired fees to deposit token decimals (assuming 1:1 for stables)
    uint256 pairedFeesNormalized = _normalizeDecimals(pairedFees, pairedTokenDecimals, depositTokenDecimals);

    // Total fees in deposit token terms
    uint256 totalFees = depositFees + pairedFeesNormalized;

    // Convert fees to 18 decimals for consistent addition
    uint256 feesIn18 = _toStandardDecimals(totalFees, depositTokenDecimals);

    // Total value in 18 decimals
    uint256 totalValueIn18 = liquidityValue + feesIn18;

    // Convert to deposit token decimals
    if (depositTokenDecimals >= 18) {
        return totalValueIn18 * (10 ** (depositTokenDecimals - 18));
    } else {
        return totalValueIn18 / (10 ** (18 - depositTokenDecimals));
    }
}
```

**Justification:** Now `totalBalanceOf()` correctly reflects principal + accrued fees, enabling proper surplus calculation.

### Phase 4: Remove `collectYield()` and Internalize Fee Collection

Remove the external `collectYield()` function entirely and integrate fee collection into `_withdrawFrom()`:

```solidity
function _withdrawFrom(address token, address client, uint256 amount, address recipient) internal override {
    if (token != address(depositToken)) revert InvalidToken();

    // First collect any pending fees - fees are now held as token balances in this contract
    (uint256 collectedDepositFees, uint256 collectedPairedFees) = _collectAndConvertFees();

    // Calculate how much of the collected fees belong to this client (proportional to their principal)
    uint256 clientPrincipal = clientDeposits[client];
    if (clientPrincipal == 0 || totalDeposited == 0) return;

    uint256 clientShare = (collectedDepositFees * clientPrincipal) / totalDeposited;

    require(amount <= clientShare, "UniV4StableYieldStrategy: amount exceeds available surplus");

    // Transfer the requested amount to recipient
    if (amount > 0) {
        depositToken.safeTransfer(recipient, amount);
    }

    // Note: clientDeposits is NOT modified for surplus withdrawals (only yield is withdrawn)
}

/**
 * @notice Collect fees from V4 and convert paired token fees to deposit token
 * @return collectedDepositFees Fees collected in deposit token
 * @return collectedPairedFees Fees collected in paired token (before conversion)
 */
function _collectAndConvertFees() internal returns (uint256 collectedDepositFees, uint256 collectedPairedFees) {
    (uint256 fees0, uint256 fees1) = _collectFees();

    // Determine which token is which based on pool key ordering
    if (address(depositToken) == poolKey.currency0) {
        collectedDepositFees = fees0;
        collectedPairedFees = fees1;
    } else {
        collectedDepositFees = fees1;
        collectedPairedFees = fees0;
    }

    // Swap paired token fees to deposit token
    if (collectedPairedFees > 0) {
        uint256 swappedAmount = _swapWithSlippageCheck(pairedToken, depositToken, collectedPairedFees);
        collectedDepositFees += swappedAmount;
    }

    return (collectedDepositFees, collectedPairedFees);
}
```

**Justification:**
- Eliminates the vulnerability entirely by removing external access to fee collection
- Fees are only collected when an authorized withdrawer calls `withdrawFrom()`
- Simpler architecture - fee collection is an implementation detail, not a user-facing function
- Aligns with the `stableYieldAccumulator` workflow which only interacts via `withdrawFrom()`

---

## Testing Requirements

### Unit Tests

1. **Fee Calculation Tests**
   - Test `_calculatePendingFees()` with various tick positions
   - Test fee growth inside calculation for all three cases (below, within, above range)
   - Test decimal normalization in fee calculations

2. **Integration Tests**
   - Test `totalBalanceOf()` returns principal + fees after fees accrue
   - Test `pendingYield()` returns correct values
   - Test surplus calculation: `totalBalanceOf() - principalOf() > 0` after fees accrue

3. **Fee Collection Integration Tests**
   - Test that `_collectAndConvertFees()` correctly collects and swaps fees
   - Test that `withdrawFrom()` properly collects fees before calculating surplus
   - Test that fees are proportionally distributed based on client principal

4. **StableYieldAccumulator Integration Tests**
   - Mock the accumulator workflow: query balance → calculate surplus → withdraw
   - Verify fees are correctly transferred to recipient

### Mock Requirements

The test suite will need to mock `IPoolManager` with realistic fee growth values. Consider:
- Creating `MockPoolManager` that simulates fee accrual over time
- Testing edge cases: zero fees, large fees, decimal edge cases (6/6, 18/18, 6/18 combinations)

---

## Migration Considerations

### Breaking Changes

1. `IPoolManager` interface changes require updating mock contracts
2. `collectYield()` is removed entirely - any existing integrations that call it directly will break (this is intentional as those calls were unauthorized fee extraction)

### Deployment Steps

1. Deploy updated `UniV4StableYieldStrategy`
2. Authorize appropriate addresses as withdrawers via `setWithdrawer()` (required for `withdrawFrom()` to work)
3. Downstream consumers interact only via `withdrawFrom()` - no direct fee collection needed

---

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Fee calculation math error | High | Extensive testing, use proven V3 algorithm |
| Overflow in fee calculation | Medium | Use checked math, test with extreme values |
| Rounding errors in decimal conversion | Low | Accept minor dust amounts, document expected precision |
| Interface mismatch with actual V4 | Medium | Verify against V4 mainnet deployment before production |

---

## Summary

| Issue | Current State | Fixed State |
|-------|---------------|-------------|
| `collectYield()` | External, anyone can call and steal fees | Removed; fee collection internalized to `_withdrawFrom()` |
| `pendingYield()` | Returns (0, 0) | Returns actual pending fees |
| `_estimateTotalValue()` | Ignores fees | Includes pending fees |
| `totalBalanceOf()` | ≈ principal | principal + yield |
| Surplus calculation | Always ~0 | Correctly reflects yield |

This fix aligns the contract with the `stableYieldAccumulator`'s expectations and closes the vulnerability allowing fee theft.
