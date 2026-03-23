# AutoFinance YieldStrategy Refactoring Plan

## Overview

Refactor the existing `AutoDolaYieldStrategy` into a generic `AutoPoolYieldStrategy` that can support any Auto Finance autopool (autoDOLA, autoUSD, autoETH, etc.) while preserving the legacy implementation for existing mainnet deployments.

## Motivation

- autoUSD (USDC-based) uses the same interaction pattern as autoDOLA
- Future autopools (autoETH, etc.) will likely follow the same pattern
- Reduces code duplication and maintenance burden
- Single audited codebase for all Auto Finance integrations

## Directory Structure Changes

### Before
```
src/
├── concreteYieldStrategies/
│   └── AutoDolaYieldStrategy.sol
├── imports/
│   ├── IAutoDOLA.sol
│   └── IMainRewarder.sol
```

### After
```
src/
├── concreteYieldStrategies/
│   ├── AutoPoolYieldStrategy.sol          # New generic implementation
│   └── Legacy/
│       └── phase1/
│           └── AutoDolaYieldStrategy.sol  # Preserved for mainnet deployments
├── imports/
│   ├── IAutoPool.sol                      # New generic interface
│   ├── IMainRewarder.sol                  # Unchanged
│   └── Legacy/
│       └── IAutoDOLA.sol                  # Preserved for legacy contract
```

## Implementation Tasks

### Task 1: Create Generic Interface `IAutoPool.sol`

**File:** `src/imports/IAutoPool.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IAutoPool
 * @notice Generic interface for Auto Finance autopool vaults (autoDOLA, autoUSD, autoETH, etc.)
 * @dev Extends ERC4626 standard for yield-bearing vault functionality
 */
interface IAutoPool is IERC4626 {
    /**
     * @notice Returns the MainRewarder contract address for TOKE rewards
     * @return The address of the MainRewarder contract
     */
    function rewarder() external view returns (address);
}
```

**Notes:**
- Removed `getVaultInfo()` from the interface as it's not used in the strategy
- If `getVaultInfo()` is needed, it can be added back - verify autoUSD has the same signature first

### Task 2: Create Generic `AutoPoolYieldStrategy.sol`

**File:** `src/concreteYieldStrategies/AutoPoolYieldStrategy.sol`

**Key changes from AutoDolaYieldStrategy:**

| Original | Generic |
|----------|---------|
| `dolaToken` | `underlyingToken` |
| `autoDolaVault` | `autoPoolVault` |
| `IAutoDOLA` | `IAutoPool` |
| `DolaDeposited` event | `Deposited` event |
| `DolaWithdrawn` event | `Withdrawn` event |
| Error: "only DOLA token supported" | "only underlying token supported" |

**Constructor signature:**
```solidity
constructor(
    address _owner,
    address _underlyingToken,   // DOLA, USDC, WETH, etc.
    address _tokeToken,
    address _autoPoolVault,     // autoDOLA, autoUSD, autoETH address
    address _mainRewarder
) AYieldStrategy(_owner)
```

**New helper view function:**
```solidity
/**
 * @notice Returns the underlying token address this strategy accepts
 * @return The address of the underlying token (DOLA, USDC, etc.)
 */
function underlying() external view returns (address) {
    return address(underlyingToken);
}
```

### Task 3: Move Legacy Implementation

**Action:** Move existing files to legacy directories

1. Move `src/concreteYieldStrategies/AutoDolaYieldStrategy.sol`
   → `src/concreteYieldStrategies/Legacy/phase1/AutoDolaYieldStrategy.sol`

2. Move `src/imports/IAutoDOLA.sol`
   → `src/imports/Legacy/IAutoDOLA.sol`

3. Update import path in legacy `AutoDolaYieldStrategy.sol`:
   ```solidity
   // Before
   import "../imports/IAutoDOLA.sol";

   // After
   import "../../imports/Legacy/IAutoDOLA.sol";
   ```

4. Update other import paths in legacy file:
   ```solidity
   // Before
   import "../AYieldStrategy.sol";
   import "../imports/IMainRewarder.sol";

   // After
   import "../../AYieldStrategy.sol";
   import "../../imports/IMainRewarder.sol";
   ```

### Task 4: Update Tests

**Action:** Create new test file and preserve legacy tests

1. Create `test/unit/AutoPoolYieldStrategy.t.sol` - generic tests
2. Move `test/unit/AutoDolaYieldStrategy.t.sol` → `test/unit/Legacy/phase1/AutoDolaYieldStrategy.t.sol`
3. Update import paths in legacy test file

**New test structure:**
```
test/
├── unit/
│   ├── AutoPoolYieldStrategy.t.sol        # New generic tests
│   └── Legacy/
│       └── phase1/
│           └── AutoDolaYieldStrategy.t.sol # Preserved legacy tests
```

### Task 5: Create Mock for Generic Testing

**File:** `test/mocks/MockAutoPool.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/imports/IAutoPool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockAutoPool
 * @notice Generic mock for any Auto Finance autopool vault
 */
contract MockAutoPool is ERC20, IAutoPool {
    // Parameterized for any underlying token
    IERC20 public underlyingAsset;
    address public rewarderAddress;

    constructor(
        string memory _name,
        string memory _symbol,
        address _underlying,
        address _rewarder
    ) ERC20(_name, _symbol) {
        underlyingAsset = IERC20(_underlying);
        rewarderAddress = _rewarder;
    }

    // ... ERC4626 implementation
}
```

## Verification Checklist

Before implementing, verify the following about autoUSD:

- [ ] autoUSD contract is deployed and verified on mainnet
- [ ] autoUSD implements the same `rewarder()` function
- [ ] autoUSD MainRewarder uses same `stake()`, `withdraw()`, `earned()`, `getReward()` signatures
- [ ] TOKE is the reward token for autoUSD (same as autoDOLA)

## Deployment Considerations

### Existing Mainnet Deployments (Phase 1 Legacy)
- 2 deployments of `AutoDolaYieldStrategy` currently on mainnet
- These will continue to work with their existing interfaces
- No migration needed until those deployments are sunset

### New Deployments
- Use `AutoPoolYieldStrategy` for all new deployments
- Pass appropriate constructor arguments for the specific autopool

### Example Deployments

**For autoDOLA:**
```solidity
AutoPoolYieldStrategy autoDola = new AutoPoolYieldStrategy(
    owner,
    0x865377367054516e17014CcDeD1e7d814EDC9ce4, // DOLA
    0x2e9d63788249371f1DFC918a52f8d799F4a38C94, // TOKE
    0xAutoDOLAVaultAddress,
    0xAutoDOLAMainRewarderAddress
);
```

**For autoUSD:**
```solidity
AutoPoolYieldStrategy autoUsd = new AutoPoolYieldStrategy(
    owner,
    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
    0x2e9d63788249371f1DFC918a52f8d799F4a38C94, // TOKE
    0xAutoUSDVaultAddress,
    0xAutoUSDMainRewarderAddress
);
```

## Migration Path

```
Phase 1 (Current)
├── AutoDolaYieldStrategy deployed on mainnet (2 instances)
└── No changes needed to existing deployments

Phase 2 (This Refactor)
├── Implement AutoPoolYieldStrategy
├── Move legacy code to Legacy/phase1/
├── Deploy new autoUSD strategy using generic contract
└── Legacy deployments continue operating

Phase 3 (Future)
├── Sunset legacy mainnet deployments
├── Migrate users to new generic strategy deployments
└── Legacy code kept for reference/emergency

Phase 4 (Cleanup - Optional)
└── Remove Legacy directory once all phase1 deployments are fully deprecated
```

## Risk Considerations

1. **Interface Compatibility**: If autoUSD has different interface methods, the generic approach may need adjustments. Verify before implementing.

2. **Reward Token Differences**: Confirm TOKE is the reward token for all autopools. If different pools have different reward tokens, the strategy may need modification.

3. **Decimal Handling**: USDC has 6 decimals vs DOLA's 18 decimals. The ERC4626 standard should handle this, but verify calculations work correctly in tests.

4. **Gas Costs**: No expected changes to gas costs as the logic is identical.

## Files to Create/Modify Summary

| Action | File |
|--------|------|
| CREATE | `src/imports/IAutoPool.sol` |
| CREATE | `src/concreteYieldStrategies/AutoPoolYieldStrategy.sol` |
| CREATE | `src/imports/Legacy/` (directory) |
| CREATE | `src/concreteYieldStrategies/Legacy/phase1/` (directory) |
| MOVE | `src/imports/IAutoDOLA.sol` → `src/imports/Legacy/IAutoDOLA.sol` |
| MOVE | `src/concreteYieldStrategies/AutoDolaYieldStrategy.sol` → `src/concreteYieldStrategies/Legacy/phase1/AutoDolaYieldStrategy.sol` |
| MODIFY | Legacy `AutoDolaYieldStrategy.sol` import paths |
| CREATE | `test/unit/AutoPoolYieldStrategy.t.sol` |
| CREATE | `test/unit/Legacy/phase1/` (directory) |
| MOVE | `test/unit/AutoDolaYieldStrategy.t.sol` → `test/unit/Legacy/phase1/AutoDolaYieldStrategy.t.sol` |
| MODIFY | Legacy test import paths |
| CREATE | `test/mocks/MockAutoPool.sol` |

## Estimated Scope

- New code: ~400 lines (strategy + interface + tests + mock)
- Moved/modified code: ~500 lines (legacy files with updated imports)
- Total files affected: 8-10 files
