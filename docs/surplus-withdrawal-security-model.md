# Surplus Withdrawal Security Model

## Overview

This document details the authorization flow and security model for the percentage-based surplus withdrawal feature implemented in stories 009.1-009.3. The feature enables authorized withdrawers to extract accumulated yield surplus from client vault balances.

## What is Surplus?

**Surplus** represents yield that has accumulated in vaults but is not tracked in client internal accounting.

### Example: Behodler Integration
- **Client Internal Accounting**: Behodler tracks `virtualInputTokens` (what they think they deposited)
- **Vault Actual Balance**: `balanceOf(token, client)` (deposits + accumulated yield)
- **Surplus**: The difference between vault balance and internal balance

When yield-generating vaults (like AutoDolaYieldStrategy) accumulate interest, the vault's actual token balance grows while the client's internal accounting remains static. This delta is the harvestable surplus.

## Architecture Components

### 1. Vault Contract (Base Authorization Layer)

**Location**: `src/AYieldStrategy.sol`

**Key State Variables**:
```solidity
mapping(address => bool) public authorizedWithdrawers;
```

**Authorization Functions**:
- `setWithdrawer(address withdrawer, bool auth)` - Only callable by vault owner
- `withdrawFrom(token, client, amount, recipient)` - Only callable by authorized withdrawers

**Security Features**:
- `onlyOwner` modifier protects authorization changes
- `onlyAuthorizedWithdrawer` modifier protects withdrawFrom
- `ReentrancyGuard` protects against reentrancy attacks
- Comprehensive input validation (zero address checks, amount > 0)
- Balance validation before withdrawal

**Events**:
- `WithdrawerAuthorizationSet(address indexed withdrawer, bool authorized)`
- `WithdrawnFrom(address indexed token, address indexed client, address indexed withdrawer, uint256 amount, address recipient)`

### 2. SurplusTracker Contract (Read-Only Calculation)

**Location**: `src/SurplusTracker.sol`

**Purpose**: Provides view function to calculate surplus across all vault types.

**Key Function**:
```solidity
function getSurplus(
    address vault,
    address token,
    address client,
    uint256 clientInternalBalance
) external view returns (uint256)
```

**Calculation Logic**:
1. Query `vault.balanceOf(token, client)` for actual balance
2. Compare with `clientInternalBalance` (caller-provided internal accounting)
3. Return `max(0, vaultBalance - clientInternalBalance)`

**Security Considerations**:
- Read-only contract (cannot modify state)
- No authorization required (pure calculation)
- Caller must provide accurate `clientInternalBalance` from their system
- Zero address validation for all inputs

### 3. SurplusWithdrawer Contract (State-Changing Orchestrator)

**Location**: `src/SurplusWithdrawer.sol`

**Purpose**: Orchestrates percentage-based surplus withdrawals using SurplusTracker for calculation and Vault.withdrawFrom for execution.

**Key State Variables**:
```solidity
ISurplusTracker public immutable surplusTracker;
```

**Authorization**: Only owner (recommend multisig) can call `withdrawSurplusPercent`

**Key Function**:
```solidity
function withdrawSurplusPercent(
    address vault,
    address token,
    address client,
    uint256 clientInternalBalance,
    uint256 percentage,
    address recipient
) external onlyOwner returns (uint256)
```

**Security Features**:
- `onlyOwner` modifier (Ownable from OpenZeppelin)
- Percentage validation: `require(percentage > 0 && percentage <= 100)`
- Zero address validation for all address parameters
- Surplus existence check: `require(surplus > 0)`
- Non-zero withdrawal check: `require(withdrawAmount > 0)`

**Calculation Logic**:
1. Calculate surplus via `surplusTracker.getSurplus(...)`
2. Calculate withdrawal: `(surplus * percentage) / 100`
3. Execute withdrawal via `vault.withdrawFrom(...)`

## Authorization Flow

### Level 1: Vault Owner Authorization

**Role**: Vault Owner (recommend multisig)

**Capabilities**:
- Authorize/deauthorize withdrawer addresses via `vault.setWithdrawer()`
- Change vault configuration
- Perform emergency operations

**Trust Requirements**:
- Vault owner has complete control over authorized withdrawers
- Owner can authorize any address as a withdrawer
- Owner can revoke withdrawer authorization at any time

**Best Practice**: Use a multisig wallet (e.g., Gnosis Safe) as vault owner for distributed control and transparency.

### Level 2: Authorized Withdrawer

**Role**: Authorized Withdrawer Contract (e.g., SurplusWithdrawer)

**Capabilities**:
- Call `vault.withdrawFrom()` to extract tokens from client balances
- Access ANY client balance in the vault (no per-client restrictions)
- Specify arbitrary amounts and recipients

**Trust Requirements**:
- Withdrawer can access all client funds in the vault
- Withdrawer must implement proper access controls internally
- Withdrawer logic must be correct and secure

**Best Practice**: Only authorize well-audited, purpose-built withdrawer contracts. DO NOT authorize EOAs (externally owned accounts) as withdrawers.

### Level 3: Withdrawer Owner/Operator

**Role**: SurplusWithdrawer Owner (recommend multisig)

**Capabilities**:
- Call `withdrawer.withdrawSurplusPercent()` to initiate withdrawals
- Specify percentage, client, and recipient parameters
- Control where withdrawn funds are sent

**Trust Requirements**:
- Must provide accurate `clientInternalBalance` from client's accounting system
- Controls percentage of surplus to withdraw (1-100%)
- Determines recipient address for withdrawn funds

**Best Practice**: Use a multisig wallet as SurplusWithdrawer owner for operational oversight and transparency.

## Trust Model

### Critical Trust Assumptions

1. **Vault Owner Trust**:
   - The vault owner is trusted to only authorize legitimate withdrawers
   - Malicious vault owner can authorize a withdrawer that drains all client funds
   - **Mitigation**: Use multisig with multiple trusted signers

2. **Authorized Withdrawer Trust**:
   - Authorized withdrawers have unrestricted access to client balances
   - Withdrawer contract bugs or exploits can drain client funds
   - **Mitigation**: Only authorize audited, battle-tested contracts

3. **Client Internal Balance Trust**:
   - SurplusWithdrawer owner must provide accurate `clientInternalBalance`
   - Incorrect values could result in over-withdrawal (withdrawing principal, not just surplus)
   - **Mitigation**: Implement on-chain balance tracking or oracle integration for verification

4. **Recipient Address Trust**:
   - SurplusWithdrawer owner controls recipient address
   - Funds could be sent to unauthorized addresses
   - **Mitigation**: Implement recipient whitelist or governance-approved destination addresses

### What Authorized Withdrawers CAN Do

- Withdraw from any client balance in the vault
- Specify any withdrawal amount (up to client's vault balance)
- Send withdrawn funds to any recipient address
- Trigger withdrawals at any time (no rate limiting in base contract)

### What Authorized Withdrawers CANNOT Do

- Bypass ReentrancyGuard protection
- Withdraw more than client's actual vault balance (enforced by Vault contract)
- Modify vault authorization settings (only owner can do this)
- Access other vaults where they are not authorized

## Percentage Validation Boundaries

The SurplusWithdrawer contract enforces strict percentage validation to prevent over-withdrawal.

### Valid Percentage Range

**Requirement**: `1 <= percentage <= 100`

### Validation Logic

```solidity
require(percentage > 0 && percentage <= 100, "SurplusWithdrawer: percentage must be between 1 and 100");
```

### Edge Cases

1. **0% Withdrawal**: Reverts with validation error (not permitted)
2. **1% Withdrawal**: Valid - withdraws 1% of surplus
3. **100% Withdrawal**: Valid - withdraws entire surplus
4. **101% Withdrawal**: Reverts with validation error

### Withdrawal Amount Calculation

```solidity
uint256 withdrawAmount = (surplus * percentage) / 100;
```

**Safety Properties**:
- Maximum withdrawal is 100% of surplus: `(surplus * 100) / 100 = surplus`
- Withdrawal cannot exceed surplus (percentage capped at 100)
- Integer division rounds down (slightly conservative, cannot over-withdraw)

### Non-Zero Withdrawal Check

After calculating `withdrawAmount`, the contract validates:

```solidity
require(withdrawAmount > 0, "SurplusWithdrawer: withdraw amount must be greater than zero");
```

This prevents:
- Withdrawals when surplus is 0
- Withdrawals where `(surplus * percentage) / 100` rounds down to 0 (very small surpluses)

## Security Boundaries

### What Prevents Principal Withdrawal?

The system relies on accurate `clientInternalBalance` to distinguish surplus from principal:

1. **Caller Responsibility**: SurplusWithdrawer owner must provide correct `clientInternalBalance`
2. **Calculation**: `surplus = max(0, vaultBalance - clientInternalBalance)`
3. **If clientInternalBalance is accurate**: Only surplus can be withdrawn
4. **If clientInternalBalance is wrong**: Principal could be withdrawn

**Critical Security Requirement**: The system MUST have a reliable source for client internal balance. This could be:
- On-chain balance tracking contract
- Oracle integration
- Manual governance approval of balance values
- Direct integration with client contract's accounting system

### Reentrancy Protection

All state-changing functions use OpenZeppelin's `ReentrancyGuard`:
- `Vault.withdrawFrom()` is protected
- `SurplusWithdrawer.withdrawSurplusPercent()` calls protected function

This prevents:
- Recursive withdrawal attacks
- State manipulation during token transfers

### Access Control Layers

**Three layers of access control**:

1. **Vault Owner** controls who can be a withdrawer
2. **Authorized Withdrawer** (contract) implements internal logic
3. **Withdrawer Owner** (multisig) controls operational parameters

Each layer provides defense-in-depth against unauthorized access.

## Recommended Multisig Configuration

### Vault Owner Multisig

**Recommended Setup**: 3-of-5 or 4-of-7 Gnosis Safe

**Signers**:
- Protocol founders/core team (2-3 seats)
- Community representatives (1-2 seats)
- Security experts or auditors (1-2 seats)

**Responsibilities**:
- Authorize/deauthorize withdrawer contracts
- Emergency response to security incidents
- Vault configuration changes

### SurplusWithdrawer Owner Multisig

**Recommended Setup**: 2-of-3 or 3-of-5 Gnosis Safe

**Signers**:
- Protocol treasury managers (2 seats)
- Community representatives (1 seat)
- Additional oversight (1-2 seats for larger configurations)

**Responsibilities**:
- Initiate surplus withdrawals
- Determine withdrawal percentages
- Specify recipient addresses (typically protocol treasury)

## Security Event Monitoring

All critical operations emit events for transparency and monitoring:

### Vault Events

```solidity
event WithdrawerAuthorizationSet(address indexed withdrawer, bool authorized);
event WithdrawnFrom(address indexed token, address indexed client, address indexed withdrawer, uint256 amount, address recipient);
```

### SurplusWithdrawer Events

```solidity
event SurplusWithdrawn(address indexed vault, address indexed token, address indexed client, uint256 percentage, uint256 amount, address recipient);
```

### Recommended Monitoring Setup

1. **Real-time Alerts**:
   - Monitor `WithdrawerAuthorizationSet` for unexpected authorization changes
   - Alert on `WithdrawnFrom` and `SurplusWithdrawn` events
   - Track recipient addresses against whitelist

2. **Dashboard Metrics**:
   - Total surplus withdrawn per period
   - Withdrawal frequency
   - Average withdrawal percentage
   - Client balance changes

3. **Anomaly Detection**:
   - Unusual withdrawal amounts (statistical outliers)
   - High-frequency withdrawals
   - Withdrawals to new recipient addresses
   - Authorization changes followed by immediate withdrawals

## Attack Scenarios and Mitigations

### Scenario 1: Malicious Withdrawer Authorization

**Attack**: Vault owner authorizes malicious contract as withdrawer, which drains client funds.

**Mitigations**:
- Use multisig for vault owner (requires collusion)
- Timelock on authorization changes (allows community review)
- Monitor `WithdrawerAuthorizationSet` events
- Regular audits of authorized withdrawers

### Scenario 2: Incorrect Client Internal Balance

**Attack**: SurplusWithdrawer owner provides artificially low `clientInternalBalance`, causing principal withdrawal.

**Mitigations**:
- Integrate with on-chain balance tracking
- Require governance approval for balance values
- Implement oracle-based balance verification
- Monitor withdrawal amounts against expected surplus

### Scenario 3: Reentrancy Attack

**Attack**: Malicious token contract attempts to re-enter during withdrawal.

**Mitigations**:
- OpenZeppelin `ReentrancyGuard` on all state-changing functions (IMPLEMENTED)
- Checks-Effects-Interactions pattern in withdrawal logic
- Only support standard ERC20 tokens (no exotic transfer hooks)

### Scenario 4: Withdrawer Contract Bug

**Attack**: Bug in SurplusWithdrawer contract allows unauthorized withdrawals or incorrect calculations.

**Mitigations**:
- Comprehensive test suite (175 tests, all passing)
- Professional security audit before production deployment
- Gradual rollout with small withdrawal limits initially
- Emergency pause mechanism (can deauthorize withdrawer)

### Scenario 5: Recipient Address Manipulation

**Attack**: SurplusWithdrawer owner sends funds to personal address instead of protocol treasury.

**Mitigations**:
- Use multisig for SurplusWithdrawer owner (requires collusion)
- Implement recipient address whitelist
- Governance approval for recipient changes
- Transparent monitoring of all withdrawals

## Security Recommendations

### Pre-Deployment

1. **Professional Security Audit**: Engage reputable auditing firm for comprehensive review
2. **Formal Verification**: Consider formal verification of critical invariants
3. **Testnet Deployment**: Extensive testing on testnet with realistic scenarios
4. **Community Review**: Public review period for community feedback

### Deployment Configuration

1. **Multisig Setup**:
   - Deploy Gnosis Safe for vault owner
   - Deploy separate Gnosis Safe for SurplusWithdrawer owner
   - Test multisig operations on testnet first

2. **Initial Authorization**:
   - Only authorize audited SurplusWithdrawer contract
   - Document authorization decision in governance proposal
   - Announce authorization with public notice period

3. **Monitoring Setup**:
   - Configure event monitoring before authorization
   - Set up alerting thresholds and notification channels
   - Create public dashboard for transparency

### Post-Deployment

1. **Gradual Rollout**:
   - Start with low percentage withdrawals (e.g., 10%)
   - Gradually increase after confirming correct operation
   - Monitor client balances for any anomalies

2. **Regular Review**:
   - Quarterly review of authorized withdrawers
   - Monthly audit of withdrawal history
   - Annual security reassessment

3. **Incident Response Plan**:
   - Document emergency deauthorization procedure
   - Define escalation criteria for security events
   - Maintain communication channels for rapid response

4. **Community Transparency**:
   - Regular reports on surplus withdrawals
   - Public announcement of all authorization changes
   - Open-source all contracts and documentation

## Invariants and Assumptions

### Critical Invariants

1. **Balance Conservation**: Total tokens in vault should only decrease by withdrawal amounts (tracked via events)
2. **Authorization Integrity**: Only vault owner can modify authorized withdrawers
3. **Surplus Calculation**: Surplus is always `max(0, vaultBalance - clientInternalBalance)`
4. **Percentage Bounds**: Withdrawal percentage is always between 1 and 100 (inclusive)
5. **Withdrawal Amount**: Withdrawal never exceeds calculated surplus (when `clientInternalBalance` is accurate)

### System Assumptions

1. **Client Internal Balance Accuracy**: Caller provides correct client internal balance
2. **Vault Owner Integrity**: Vault owner acts in best interest of protocol and clients
3. **Token Standard Compliance**: Tokens are standard ERC20 (no transfer hooks, reentrancy)
4. **Withdrawer Contract Correctness**: Authorized withdrawer contracts are bug-free and audited
5. **Multisig Signer Trust**: Majority of multisig signers are honest and vigilant

### Known Limitations

1. **No On-Chain Balance Verification**: System cannot verify client internal balance on-chain
2. **No Rate Limiting**: No built-in limits on withdrawal frequency or amounts
3. **No Recipient Whitelist**: Withdrawer owner can specify any recipient address
4. **No Automated Pause**: No circuit breaker for anomalous withdrawal patterns
5. **No Time-Based Controls**: No timelock or delay on withdrawals

**Recommendation**: Consider implementing additional safeguards (rate limiting, recipient whitelist, circuit breakers) in future versions or through external governance mechanisms.

## Comparison with Alternative Approaches

### Alternative 1: All-or-Nothing Withdrawal

**Approach**: Only allow 100% surplus withdrawal.

**Advantages**:
- Simpler logic (no percentage calculation)
- Slightly lower gas costs

**Disadvantages**:
- Less flexible for treasury management
- Cannot leave safety margin of surplus in vault
- All-or-nothing creates risk if calculation is slightly off

**Decision**: Percentage-based approach chosen for flexibility and safety.

### Alternative 2: Fixed Amount Withdrawal

**Approach**: Specify withdrawal amount directly (not percentage).

**Advantages**:
- More precise control over withdrawal amounts
- Simpler for operators (specify exact amount needed)

**Disadvantages**:
- Requires operator to calculate percentage manually
- No built-in protection against over-withdrawal
- Less intuitive for surplus harvesting use case

**Decision**: Percentage-based approach provides better safety properties for surplus-specific withdrawals.

### Alternative 3: On-Chain Balance Tracking

**Approach**: Store client internal balances on-chain in separate contract.

**Advantages**:
- Eliminates trust requirement for client balance accuracy
- Enables automated verification
- Stronger security guarantees

**Disadvantages**:
- Requires significant integration changes with client contracts
- Increased gas costs for balance updates
- Less flexible for different client accounting systems

**Decision**: Current approach prioritizes flexibility and integration simplicity. On-chain balance tracking can be added in future version.

## References

### Contract Implementations

- Vault.sol: Lines 168-174 (setWithdrawer), Lines 234-253 (withdrawFrom)
- SurplusTracker.sol: Lines 31-51 (getSurplus)
- SurplusWithdrawer.sol: Lines 52-81 (withdrawSurplusPercent)

### Test Coverage

- VaultWithdrawer.t.sol: 23 tests for vault withdrawer functionality
- SurplusTracker.t.sol: 17 unit tests for surplus tracking
- SurplusTrackerIntegration.t.sol: 10 integration tests across vault types
- SurplusWithdrawer.t.sol: 23 tests for percentage-based withdrawals

### Related Stories

- Story 009.1: Vault Contract Enhancements
- Story 009.2: SurplusTracker Contract
- Story 009.3: SurplusWithdrawer Contract
- Story 009.4: Documentation & Deployment (this document)

---

**Document Version**: 1.0
**Last Updated**: 2025-10-06
**Authors**: Vault-RM Development Team
**Status**: Final
