# Surplus Withdrawal Feature - Production Deployment Checklist

## Overview

This checklist provides step-by-step procedures for deploying the percentage-based surplus withdrawal feature to production. The feature consists of three contracts deployed across stories 009.1-009.3.

## Pre-Deployment Requirements

### Code Readiness

- [ ] All tests passing (verify with `forge test`)
  - Expected: 175 tests passing, 0 failures
  - Run: `cd /path/to/vault-RM && forge test`
- [ ] Gas snapshots generated and reviewed
  - Run: `forge snapshot`
  - Review `.gas-snapshot` file for reasonable costs
- [ ] Code coverage analysis complete
  - Run: `forge coverage`
  - Target: >95% coverage for new contracts
- [ ] Static analysis completed (Slither, if available)
  - Run: `slither .` (if installed)
  - Review and resolve all high/medium severity findings
- [ ] Formal verification completed (if applicable)
  - Document verification results and assumptions

### Security Review

- [ ] Professional security audit completed
  - Engage reputable auditing firm (e.g., Trail of Bits, OpenZeppelin, Consensys Diligence)
  - Address all critical and high severity findings
  - Document risk acceptance for any unresolved medium/low findings
- [ ] Internal code review completed
  - At least 2 senior developers review all changes
  - Focus on: access control, reentrancy, arithmetic, edge cases
- [ ] Community review period completed
  - Minimum 2-week public review period
  - Address all reasonable community concerns
  - Document review feedback and responses

### Infrastructure Setup

- [ ] Deployment wallet prepared and secured
  - Use hardware wallet (Ledger/Trezor) for mainnet deployment
  - Verify wallet has sufficient ETH for gas
  - Test deployment on testnet first
- [ ] Multisig wallets deployed and tested
  - Deploy Gnosis Safe for vault owner role
  - Deploy separate Gnosis Safe for SurplusWithdrawer owner role
  - Verify all signers have access and understand procedures
  - Test multisig operations on testnet
- [ ] Monitoring infrastructure ready
  - Event monitoring configured (e.g., TheGraph, Tenderly, Alchemy)
  - Alerting thresholds defined and tested
  - Dashboard created for transparency
  - Alert notification channels configured (Discord, Telegram, email)
- [ ] Block explorer verification prepared
  - Prepare contract source code for verification
  - Test verification on testnet (Etherscan, Sourcify)
  - Document constructor parameters for verification

### Environment Configuration

- [ ] Network parameters confirmed
  - Target network identified (e.g., Ethereum mainnet, Arbitrum, Polygon)
  - RPC endpoints configured and tested
  - Gas price strategy determined (market rate, priority, fixed)
- [ ] Client internal balance source identified
  - Determine how to obtain accurate client internal balances
  - Options: on-chain contract, oracle, manual governance approval
  - Test balance retrieval mechanism
- [ ] Recipient addresses determined
  - Define protocol treasury address(es)
  - Create recipient whitelist (if implementing)
  - Document approval process for recipient changes

## Deployment Steps

### Phase 1: Testnet Deployment

#### Step 1.1: Deploy SurplusTracker (Story 009.2)

```bash
# Set environment variables
export NETWORK=sepolia  # or your testnet
export PRIVATE_KEY=your_testnet_deployer_key
export RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY

# Deploy SurplusTracker (no constructor arguments)
forge create --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --verify \
  src/SurplusTracker.sol:SurplusTracker

# Save deployed address
export SURPLUS_TRACKER_ADDRESS=0x...
```

**Verification Checklist**:
- [ ] Contract deployed successfully
- [ ] Transaction confirmed on block explorer
- [ ] Contract verified on Etherscan/equivalent
- [ ] `getSurplus()` function visible and callable (view)
- [ ] Record deployment address and transaction hash

#### Step 1.2: Deploy SurplusWithdrawer (Story 009.3)

```bash
# Deploy SurplusWithdrawer
# Constructor parameters:
#   - _surplusTracker: address (from Step 1.1)
#   - _owner: address (testnet multisig or test EOA)

export TESTNET_MULTISIG=0x...  # testnet multisig address

forge create --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --verify \
  --constructor-args $SURPLUS_TRACKER_ADDRESS $TESTNET_MULTISIG \
  src/SurplusWithdrawer.sol:SurplusWithdrawer

# Save deployed address
export SURPLUS_WITHDRAWER_ADDRESS=0x...
```

**Verification Checklist**:
- [ ] Contract deployed successfully
- [ ] Constructor parameters correct (verify on Etherscan)
  - [ ] `surplusTracker` points to deployed SurplusTracker
  - [ ] `owner` is testnet multisig address
- [ ] Contract verified on block explorer
- [ ] Record deployment address and transaction hash

#### Step 1.3: Configure Vault Authorization (Story 009.1)

```bash
# Authorize SurplusWithdrawer on existing vault
# This assumes vault is already deployed and you have owner access

# If using multisig as vault owner, prepare transaction data:
cast calldata "setWithdrawer(address,bool)" \
  $SURPLUS_WITHDRAWER_ADDRESS \
  true

# Submit to multisig via Gnosis Safe UI or CLI
# Or if using EOA for testing:
cast send --rpc-url $RPC_URL \
  --private-key $VAULT_OWNER_KEY \
  $VAULT_ADDRESS \
  "setWithdrawer(address,bool)" \
  $SURPLUS_WITHDRAWER_ADDRESS \
  true
```

**Verification Checklist**:
- [ ] Transaction confirmed successfully
- [ ] `WithdrawerAuthorizationSet` event emitted
  - [ ] `withdrawer` parameter matches SurplusWithdrawer address
  - [ ] `authorized` parameter is `true`
- [ ] Verify authorization: `vault.authorizedWithdrawers(SURPLUS_WITHDRAWER_ADDRESS)` returns `true`
- [ ] Record authorization transaction hash

### Phase 2: Testnet Testing

#### Step 2.1: Setup Test Scenario

- [ ] Identify test client with vault balance
  - If none exists, create test deposits to generate vault balance
- [ ] Determine test client's internal balance
  - For testing, can use arbitrary value less than vault balance
- [ ] Calculate expected surplus
  - `surplus = vaultBalance - clientInternalBalance`

#### Step 2.2: Execute Test Withdrawal

```bash
# Prepare withdrawal parameters
export VAULT_ADDRESS=0x...
export TOKEN_ADDRESS=0x...  # token to withdraw
export CLIENT_ADDRESS=0x...  # client with surplus
export CLIENT_INTERNAL_BALANCE=1000000000000000000000  # example: 1000e18
export PERCENTAGE=10  # 10% test withdrawal
export RECIPIENT_ADDRESS=0x...  # where to send withdrawn surplus

# Prepare transaction data for multisig
cast calldata "withdrawSurplusPercent(address,address,address,uint256,uint256,address)" \
  $VAULT_ADDRESS \
  $TOKEN_ADDRESS \
  $CLIENT_ADDRESS \
  $CLIENT_INTERNAL_BALANCE \
  $PERCENTAGE \
  $RECIPIENT_ADDRESS

# Execute via multisig (Gnosis Safe UI) or direct call for testing
cast send --rpc-url $RPC_URL \
  --private-key $MULTISIG_OWNER_KEY \
  $SURPLUS_WITHDRAWER_ADDRESS \
  "withdrawSurplusPercent(address,address,address,uint256,uint256,address)" \
  $VAULT_ADDRESS \
  $TOKEN_ADDRESS \
  $CLIENT_ADDRESS \
  $CLIENT_INTERNAL_BALANCE \
  $PERCENTAGE \
  $RECIPIENT_ADDRESS
```

**Verification Checklist**:
- [ ] Transaction confirmed successfully
- [ ] Events emitted correctly:
  - [ ] `SurplusWithdrawn` from SurplusWithdrawer
  - [ ] `WithdrawnFrom` from Vault
- [ ] Verify event parameters match inputs
- [ ] Check balances changed correctly:
  - [ ] Client vault balance decreased by expected amount
  - [ ] Recipient received correct token amount
  - [ ] Amount matches `(surplus * percentage) / 100`

#### Step 2.3: Edge Case Testing

Test each of these scenarios on testnet:

- [ ] **Test 1: Zero surplus**
  - Setup: `clientInternalBalance == vaultBalance`
  - Expected: Transaction reverts with "SurplusTracker: no surplus to withdraw"

- [ ] **Test 2: Invalid percentage (0%)**
  - Setup: `percentage = 0`
  - Expected: Transaction reverts with "SurplusWithdrawer: percentage must be between 1 and 100"

- [ ] **Test 3: Invalid percentage (101%)**
  - Setup: `percentage = 101`
  - Expected: Transaction reverts with "SurplusWithdrawer: percentage must be between 1 and 100"

- [ ] **Test 4: Maximum withdrawal (100%)**
  - Setup: `percentage = 100`
  - Expected: Entire surplus withdrawn successfully

- [ ] **Test 5: Minimum withdrawal (1%)**
  - Setup: `percentage = 1`
  - Expected: 1% of surplus withdrawn successfully

- [ ] **Test 6: Unauthorized caller**
  - Setup: Non-owner calls `withdrawSurplusPercent`
  - Expected: Transaction reverts with "Ownable: caller is not the owner"

- [ ] **Test 7: Unauthorized withdrawer**
  - Setup: Deauthorize SurplusWithdrawer, attempt withdrawal
  - Expected: Transaction reverts with "Vault: unauthorized, only authorized withdrawers"

- [ ] **Test 8: Multiple consecutive withdrawals**
  - Setup: Execute 2-3 withdrawals in sequence
  - Expected: Each withdrawal succeeds with recalculated surplus

- [ ] **Test 9: Reentrancy attempt** (if using test token with hooks)
  - Setup: Token with malicious transfer hook
  - Expected: ReentrancyGuard prevents reentrancy

#### Step 2.4: Integration Testing

- [ ] Test with multiple vault types (if applicable)
  - [ ] AutoDolaVault
  - [ ] Other concrete vault implementations
- [ ] Test multisig workflow end-to-end
  - [ ] Create withdrawal transaction in Gnosis Safe
  - [ ] Collect required signatures
  - [ ] Execute transaction
  - [ ] Verify results
- [ ] Test monitoring and alerting
  - [ ] Verify events appear in monitoring dashboard
  - [ ] Confirm alerts trigger for withdrawals
  - [ ] Test alert notification delivery

### Phase 3: Mainnet Deployment

**Prerequisites**:
- [ ] All testnet testing completed successfully
- [ ] Security audit findings resolved
- [ ] Community review period completed
- [ ] Governance proposal approved (if applicable)
- [ ] Deployment team briefed and ready

#### Step 3.1: Pre-Deployment Checklist

- [ ] Mainnet RPC endpoints configured and tested
- [ ] Deployment wallet funded with sufficient ETH for gas
- [ ] Multisig wallets deployed on mainnet
  - [ ] Vault owner multisig (3-of-5 recommended)
  - [ ] SurplusWithdrawer owner multisig (2-of-3 recommended)
- [ ] All signers confirmed and have access
- [ ] Monitoring infrastructure configured for mainnet
- [ ] Emergency response plan documented and communicated
- [ ] Deployment transaction parameters finalized and reviewed

#### Step 3.2: Deploy SurplusTracker to Mainnet

```bash
# Set mainnet environment variables
export NETWORK=mainnet
export RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY
export DEPLOYER_PRIVATE_KEY=...  # Use hardware wallet recommended

# Deploy SurplusTracker
forge create --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  src/SurplusTracker.sol:SurplusTracker

# Save deployed address
export MAINNET_SURPLUS_TRACKER=0x...
```

**Post-Deployment Verification**:
- [ ] Contract deployed to expected address
- [ ] Transaction confirmed with sufficient confirmations (recommend 12+)
- [ ] Contract verified on Etherscan
- [ ] Source code matches deployed bytecode
- [ ] `getSurplus()` function accessible
- [ ] Record deployment details:
  - [ ] Contract address
  - [ ] Transaction hash
  - [ ] Block number
  - [ ] Deployer address
  - [ ] Timestamp

#### Step 3.3: Deploy SurplusWithdrawer to Mainnet

```bash
# Set mainnet multisig address
export MAINNET_OWNER_MULTISIG=0x...  # SurplusWithdrawer owner multisig

# Deploy SurplusWithdrawer
forge create --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $MAINNET_SURPLUS_TRACKER $MAINNET_OWNER_MULTISIG \
  src/SurplusWithdrawer.sol:SurplusWithdrawer

# Save deployed address
export MAINNET_SURPLUS_WITHDRAWER=0x...
```

**Post-Deployment Verification**:
- [ ] Contract deployed to expected address
- [ ] Transaction confirmed with sufficient confirmations (12+)
- [ ] Contract verified on Etherscan
- [ ] Constructor parameters verified:
  - [ ] `surplusTracker` points to mainnet SurplusTracker
  - [ ] `owner` is mainnet multisig address
- [ ] Ownership confirmed: `contract.owner()` returns multisig address
- [ ] Record deployment details (address, tx hash, block, etc.)

#### Step 3.4: Authorize SurplusWithdrawer on Vault

**Important**: This step should be done carefully with multisig and potentially with a timelock delay.

```bash
# Prepare authorization transaction for vault owner multisig
# This transaction will be created in Gnosis Safe UI

# Transaction parameters:
# To: $VAULT_ADDRESS
# Value: 0
# Data: encoded call to setWithdrawer(address,bool)

# Generate calldata
cast calldata "setWithdrawer(address,bool)" \
  $MAINNET_SURPLUS_WITHDRAWER \
  true
```

**Authorization Process**:
1. [ ] Create transaction in vault owner multisig (Gnosis Safe)
2. [ ] Review transaction parameters with all signers
3. [ ] Collect required signatures (e.g., 3-of-5)
4. [ ] If using timelock, wait for timelock delay
5. [ ] Execute authorization transaction
6. [ ] Monitor transaction confirmation

**Post-Authorization Verification**:
- [ ] Transaction confirmed with sufficient confirmations
- [ ] `WithdrawerAuthorizationSet` event emitted
  - [ ] Event parameters correct
- [ ] Authorization state verified on-chain:
  - [ ] `vault.authorizedWithdrawers(MAINNET_SURPLUS_WITHDRAWER)` returns `true`
- [ ] Monitoring alerts triggered for authorization event
- [ ] Public announcement of authorization completed
- [ ] Record authorization transaction hash and timestamp

### Phase 4: Initial Production Operations

#### Step 4.1: Gradual Rollout Plan

**Week 1: Conservative Testing**
- [ ] Execute first production withdrawal
  - Parameters:
    - Percentage: 5-10% (conservative)
    - Client: Well-understood client with verified balance
    - Amount: Small relative to total protocol value
  - [ ] Obtain accurate client internal balance
  - [ ] Calculate expected surplus and withdrawal amount
  - [ ] Prepare multisig transaction
  - [ ] Collect signatures
  - [ ] Execute transaction
  - [ ] Monitor for 24-48 hours after withdrawal

**Week 2-4: Gradual Increase**
- [ ] Increase withdrawal percentage to 25-50%
- [ ] Test with multiple clients (if applicable)
- [ ] Verify client balances remain accurate
- [ ] Monitor for any unexpected behavior

**Month 2+: Normal Operations**
- [ ] Increase to full percentage range (up to 100%)
- [ ] Establish regular withdrawal schedule (if applicable)
- [ ] Document operational procedures
- [ ] Train additional operators

#### Step 4.2: First Production Withdrawal

```bash
# Prepare first mainnet withdrawal
# Recommended: 5-10% of surplus, well-verified client

export MAINNET_VAULT=0x...
export MAINNET_TOKEN=0x...
export MAINNET_CLIENT=0x...
export CLIENT_INTERNAL_BALANCE=...  # Obtain from client's accounting system
export INITIAL_PERCENTAGE=10  # Start conservative
export MAINNET_TREASURY=0x...  # Protocol treasury address

# Calculate expected amounts BEFORE execution
# 1. Query vault balance
cast call $MAINNET_VAULT \
  "balanceOf(address,address)(uint256)" \
  $MAINNET_TOKEN \
  $MAINNET_CLIENT

# 2. Calculate surplus manually
# surplus = vaultBalance - clientInternalBalance

# 3. Calculate expected withdrawal
# expectedWithdrawal = (surplus * percentage) / 100

# 4. Document expected amounts before proceeding

# Generate transaction calldata for multisig
cast calldata "withdrawSurplusPercent(address,address,address,uint256,uint256,address)" \
  $MAINNET_VAULT \
  $MAINNET_TOKEN \
  $MAINNET_CLIENT \
  $CLIENT_INTERNAL_BALANCE \
  $INITIAL_PERCENTAGE \
  $MAINNET_TREASURY
```

**Execution Process**:
1. [ ] Create transaction in SurplusWithdrawer owner multisig
2. [ ] Review all parameters with signers
3. [ ] Double-check client internal balance accuracy
4. [ ] Verify expected withdrawal amount is reasonable
5. [ ] Collect required signatures
6. [ ] Execute transaction
7. [ ] Monitor transaction in real-time

**Post-Execution Verification**:
- [ ] Transaction confirmed successfully
- [ ] Events emitted correctly:
  - [ ] `SurplusWithdrawn` event parameters match inputs
  - [ ] `WithdrawnFrom` event parameters match inputs
- [ ] Balance changes verified:
  - [ ] Client vault balance decreased by expected amount
  - [ ] Treasury received correct token amount
  - [ ] Amount matches calculation: `(surplus * percentage) / 100`
- [ ] No unexpected events or reverts
- [ ] Monitoring dashboard shows withdrawal
- [ ] Alerts triggered appropriately
- [ ] Document results and any observations

#### Step 4.3: 48-Hour Monitoring Period

After first withdrawal, monitor for 48 hours:

- [ ] **Hour 0-2**: Active monitoring
  - [ ] Verify balances stable
  - [ ] Check for unexpected transactions
  - [ ] Monitor client contract behavior

- [ ] **Hour 2-24**: Regular monitoring
  - [ ] Check dashboard every 4-8 hours
  - [ ] Verify no anomalies in client balances
  - [ ] Review any alerts or notifications

- [ ] **Hour 24-48**: Validation
  - [ ] Verify client internal balance still accurate
  - [ ] Confirm vault balance reflects withdrawal
  - [ ] Check for any delayed effects or issues
  - [ ] Document findings for future reference

## Production Monitoring and Maintenance

### Ongoing Monitoring

- [ ] **Real-Time Monitoring**:
  - [ ] Event monitoring active for all contracts
  - [ ] Alerts configured for:
    - Authorization changes (`WithdrawerAuthorizationSet`)
    - All withdrawals (`SurplusWithdrawn`, `WithdrawnFrom`)
    - Unusual withdrawal patterns
    - New recipient addresses
  - [ ] Dashboard displaying:
    - Total surplus available per client
    - Withdrawal history (amount, percentage, timestamp)
    - Current authorized withdrawers
    - Recent events

- [ ] **Daily Checks**:
  - [ ] Review previous 24 hours of withdrawals
  - [ ] Verify no unexpected authorization changes
  - [ ] Check alert log for any issues
  - [ ] Confirm monitoring systems operational

- [ ] **Weekly Review**:
  - [ ] Analyze withdrawal patterns for anomalies
  - [ ] Review client balance accuracy
  - [ ] Check multisig signer status
  - [ ] Verify backup systems functional

- [ ] **Monthly Audit**:
  - [ ] Comprehensive review of all withdrawals
  - [ ] Client balance reconciliation
  - [ ] Security review of authorized withdrawers
  - [ ] Performance metrics analysis
  - [ ] Documentation updates

### Operational Procedures

#### Standard Withdrawal Procedure

1. **Prepare Withdrawal Request**:
   - [ ] Identify client and token
   - [ ] Obtain current client internal balance from authoritative source
   - [ ] Calculate available surplus
   - [ ] Determine withdrawal percentage (recommend <100% for safety margin)
   - [ ] Verify recipient address (protocol treasury or approved destination)

2. **Review and Approval**:
   - [ ] Document withdrawal parameters
   - [ ] Calculate expected withdrawal amount
   - [ ] Review with multisig signers
   - [ ] Obtain required approvals

3. **Execute Withdrawal**:
   - [ ] Create multisig transaction
   - [ ] Double-check all parameters
   - [ ] Collect signatures
   - [ ] Execute transaction
   - [ ] Monitor confirmation

4. **Post-Withdrawal Verification**:
   - [ ] Verify events emitted correctly
   - [ ] Confirm balance changes match expectations
   - [ ] Update internal records
   - [ ] Document withdrawal in operations log

#### Emergency Procedures

**Scenario 1: Suspected Unauthorized Withdrawal**

1. [ ] Immediately alert all vault owner multisig signers
2. [ ] Review transaction details on block explorer
3. [ ] Verify authorization status of withdrawer
4. [ ] If unauthorized: Prepare emergency deauthorization transaction
5. [ ] Collect signatures for deauthorization ASAP
6. [ ] Execute deauthorization
7. [ ] Investigate root cause
8. [ ] Document incident and response
9. [ ] Consider additional security measures

**Scenario 2: Incorrect Client Balance Leading to Principal Withdrawal**

1. [ ] Detect via balance monitoring or client report
2. [ ] Immediately cease all withdrawals for affected client
3. [ ] Assess damage: how much principal was withdrawn
4. [ ] Convene multisig signers and protocol team
5. [ ] Determine remediation plan (return funds, adjust balances, etc.)
6. [ ] Implement corrective measures
7. [ ] Review and improve balance verification process
8. [ ] Document incident for future prevention

**Scenario 3: Smart Contract Bug or Exploit**

1. [ ] Immediately deauthorize affected withdrawer contract
2. [ ] Alert all stakeholders (multisig signers, community, users)
3. [ ] Assess exploit scope and potential losses
4. [ ] Pause any related operations
5. [ ] Engage security team for analysis
6. [ ] Prepare mitigation or recovery plan
7. [ ] If necessary, deploy fixed contract version
8. [ ] Conduct post-mortem and update procedures

### Authorization Change Procedure

**Adding a New Authorized Withdrawer**:

1. [ ] **Proposal Phase**:
   - [ ] Document reason for new withdrawer
   - [ ] Provide contract address and source code
   - [ ] Security audit results for new contract
   - [ ] Governance proposal (if applicable)

2. [ ] **Review Phase**:
   - [ ] Internal code review by senior developers
   - [ ] Security team review
   - [ ] Community review period (minimum 1 week)
   - [ ] Address any concerns or questions

3. [ ] **Approval Phase**:
   - [ ] Governance vote (if applicable)
   - [ ] Multisig signer approval
   - [ ] Document approval decision

4. [ ] **Authorization Phase**:
   - [ ] Prepare `setWithdrawer(newAddress, true)` transaction
   - [ ] Create transaction in vault owner multisig
   - [ ] Collect required signatures
   - [ ] Execute authorization
   - [ ] Verify authorization on-chain
   - [ ] Public announcement of new withdrawer

**Removing an Authorized Withdrawer**:

1. [ ] **Identify Need**:
   - [ ] Security concern
   - [ ] Contract deprecated
   - [ ] Protocol upgrade
   - [ ] Emergency situation

2. [ ] **Prepare Deauthorization**:
   - [ ] Document reason for removal
   - [ ] Assess impact on operations
   - [ ] Plan alternative (if withdrawer being replaced)

3. [ ] **Execute Deauthorization**:
   - [ ] Prepare `setWithdrawer(addressToRemove, false)` transaction
   - [ ] Create transaction in vault owner multisig
   - [ ] Collect signatures (expedited for emergencies)
   - [ ] Execute deauthorization
   - [ ] Verify removal on-chain
   - [ ] Public announcement (if appropriate)

## Testing Checklist Summary

### Unit Tests (Should already be passing)
- [ ] Vault.sol: 23 tests for withdrawer functionality
- [ ] SurplusTracker.sol: 17 tests for surplus calculation
- [ ] SurplusWithdrawer.sol: 23 tests for percentage-based withdrawals

### Integration Tests
- [ ] SurplusTrackerIntegration.t.sol: 10 tests across vault types
- [ ] End-to-end withdrawal flow with multiple vault types

### Testnet Tests
- [ ] Zero surplus handling
- [ ] Percentage boundary tests (0%, 1%, 100%, 101%)
- [ ] Authorization tests (unauthorized caller, unauthorized withdrawer)
- [ ] Multiple consecutive withdrawals
- [ ] Reentrancy protection
- [ ] Multisig workflow

### Mainnet Tests (Gradual Rollout)
- [ ] First small withdrawal (5-10%)
- [ ] Medium withdrawal (25-50%)
- [ ] Large withdrawal (75-100%)
- [ ] Multiple clients (if applicable)
- [ ] Monitoring and alerting

## Documentation Checklist

- [ ] Security model documented (surplus-withdrawal-security-model.md)
- [ ] Deployment procedures documented (this file)
- [ ] Operational procedures documented
- [ ] Emergency procedures documented
- [ ] Contract addresses recorded (deployment log)
- [ ] Multisig signer list maintained
- [ ] Monitoring dashboard URL documented
- [ ] Alert configuration documented
- [ ] Public announcement prepared
- [ ] User-facing documentation updated (if applicable)

## Post-Deployment Reporting

### Deployment Report Template

```markdown
# Surplus Withdrawal Feature Deployment Report

## Deployment Summary
- **Date**: YYYY-MM-DD
- **Network**: [Mainnet/Testnet]
- **Deployer**: [Address]
- **Status**: [Success/Partial/Failed]

## Deployed Contracts

### SurplusTracker
- **Address**: 0x...
- **Transaction**: 0x...
- **Block**: #...
- **Verification**: [Verified/Pending]

### SurplusWithdrawer
- **Address**: 0x...
- **Transaction**: 0x...
- **Block**: #...
- **Owner**: 0x... (Multisig)
- **Tracker**: 0x... (SurplusTracker address)
- **Verification**: [Verified/Pending]

### Vault Authorization
- **Vault Address**: 0x...
- **Authorization Transaction**: 0x...
- **Block**: #...
- **Status**: Authorized

## Configuration

### Multisig Details
- **Vault Owner Multisig**: 0x... (X-of-Y)
- **SurplusWithdrawer Owner Multisig**: 0x... (X-of-Y)
- **Signers**: [List of signer addresses or identities]

### Monitoring
- **Dashboard URL**: [URL]
- **Event Monitoring**: [Active/Pending]
- **Alert Channels**: [Discord/Telegram/Email]

## Testing Results
- **Testnet Deployment**: [Success/Date]
- **Testnet Tests**: [All Passed/Issues]
- **First Mainnet Withdrawal**: [Pending/Completed]
- **48-Hour Monitor**: [In Progress/Completed]

## Known Issues
- [List any known issues or limitations]

## Next Steps
1. [Action item 1]
2. [Action item 2]
3. [Action item 3]

## Sign-Off
- **Deployment Lead**: [Name]
- **Security Review**: [Name/Date]
- **Approval**: [Governance/Multisig]
```

## Success Criteria

The deployment is considered successful when:

- [ ] All contracts deployed to mainnet
- [ ] All contracts verified on Etherscan
- [ ] SurplusWithdrawer authorized on vault
- [ ] First production withdrawal executed successfully
- [ ] 48-hour monitoring period completed without issues
- [ ] Monitoring and alerting operational
- [ ] Documentation complete and published
- [ ] Operations team trained
- [ ] Community announcement published

## Rollback Plan

If critical issues are discovered:

1. **Immediate Actions**:
   - [ ] Deauthorize SurplusWithdrawer via vault owner multisig
   - [ ] Alert all stakeholders
   - [ ] Assess damage and scope

2. **Investigation**:
   - [ ] Identify root cause
   - [ ] Document the issue
   - [ ] Determine if fixable or requires redeployment

3. **Resolution**:
   - [ ] If minor: Prepare fix and follow deployment process again
   - [ ] If major: Full rollback, redesign, and re-audit
   - [ ] Document lessons learned

4. **Prevention**:
   - [ ] Update testing procedures
   - [ ] Enhance monitoring
   - [ ] Improve documentation

## Contact Information

Maintain list of key contacts for deployment:

- **Deployment Lead**: [Name, Contact]
- **Security Team**: [Name, Contact]
- **Multisig Signers**: [Names, Contacts]
- **Emergency Response**: [24/7 Contact]
- **Audit Firm**: [Firm Name, Contact]

## Appendix: Command Reference

### Foundry Commands
```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/SurplusWithdrawer.t.sol

# Run with verbosity
forge test -vvv

# Generate gas snapshot
forge snapshot

# Check coverage
forge coverage

# Deploy contract
forge create --rpc-url $RPC_URL --private-key $PRIVATE_KEY src/Contract.sol:Contract

# Verify contract
forge verify-contract --chain-id 1 --constructor-args $(cast abi-encode "constructor(address,address)" $ARG1 $ARG2) $CONTRACT_ADDRESS src/Contract.sol:Contract $ETHERSCAN_API_KEY
```

### Cast Commands
```bash
# Generate calldata
cast calldata "functionName(type1,type2)" arg1 arg2

# Call view function
cast call $CONTRACT_ADDRESS "functionName()(returnType)"

# Send transaction
cast send $CONTRACT_ADDRESS "functionName(type1)" arg1

# Get transaction receipt
cast receipt $TX_HASH

# Get block number
cast block-number

# Convert units
cast --to-wei 1 ether
```

### Multisig Commands (Gnosis Safe CLI)
```bash
# Create transaction
safe-creator create $SAFE_ADDRESS $TO_ADDRESS $VALUE "$DATA"

# Sign transaction
safe-creator sign $SAFE_ADDRESS $TX_HASH

# Execute transaction
safe-creator exec $SAFE_ADDRESS $TX_HASH

# Check pending transactions
safe-creator pending $SAFE_ADDRESS
```

## Version History

- **v1.0** (2025-10-06): Initial deployment checklist
- **Future**: Update based on deployment experience and lessons learned

---

**Document Status**: Final
**Last Updated**: 2025-10-06
**Maintained By**: Vault-RM Development Team
**Next Review**: After first mainnet deployment
