// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockMainRewarder.sol";

/**
 * @title AutoDolaWithdrawalAndYieldTests
 * @notice RED PHASE TEST - Comprehensive withdrawal accounting and yield exclusion tests
 * @dev This test suite establishes expected correct behavior for AutoDolaYieldStrategy
 *      withdrawal operations. Some tests may fail due to the known leftoverShares bug
 *      on line 228 of AutoDolaYieldStrategy.sol.
 *
 *      THE BUG:
 *      Line 228: uint256 leftoverShares = sharesToUnstake - sharesUsed;
 *      This calculation is done internally and can suffer from rounding errors.
 *      Instead, the contract should query the vault for remaining shares.
 *
 *      EXPECTED BEHAVIOR: Tests describe correct withdrawal and yield exclusion behavior
 *      ACTUAL BEHAVIOR: Some tests may fail, exposing the leftoverShares calculation bug
 *
 *      This is RED phase TDD - tests define correct behavior before implementation.
 *      A future GREEN phase story (019) will fix the bugs to make tests pass.
 *
 * @dev Story 018 - Part of autoDola-integration sprint addressing withdrawal accounting
 */
contract AutoDolaWithdrawalAndYieldTests is Test {
    AutoDolaYieldStrategy public vault;
    MockERC20 public dolaToken;
    MockERC20 public tokeToken;
    MockAutoDOLA public autoDolaVault;
    MockMainRewarder public mainRewarder;

    address public owner = address(1);
    address public client1 = address(2);
    address public client2 = address(3);
    address public recipient1 = address(5);
    address public recipient2 = address(6);

    // Events from AutoDolaYieldStrategy
    event DolaDeposited(
        address indexed token,
        address indexed client,
        address indexed recipient,
        uint256 amount,
        uint256 sharesReceived
    );

    event DolaWithdrawn(
        address indexed token,
        address indexed client,
        address indexed recipient,
        uint256 amount,
        uint256 sharesBurned
    );

    function setUp() public {
        // Deploy mock tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock MainRewarder
        mainRewarder = new MockMainRewarder(address(tokeToken));

        // Deploy mock autoDOLA vault
        autoDolaVault = new MockAutoDOLA(address(dolaToken), address(mainRewarder));

        // Deploy AutoDolaYieldStrategy
        vault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Authorize clients
        vm.startPrank(owner);
        vault.setClient(client1, true);
        vault.setClient(client2, true);
        vm.stopPrank();
    }

    // ============ HELPER FUNCTIONS ============

    function _deposit(address client, uint256 amount, address recipient) internal returns (uint256 sharesReceived) {
        dolaToken.mint(client, amount);
        vm.startPrank(client);
        dolaToken.approve(address(vault), amount);

        uint256 sharesBefore = mainRewarder.balanceOf(address(vault));
        vault.deposit(address(dolaToken), amount, recipient);
        uint256 sharesAfter = mainRewarder.balanceOf(address(vault));

        vm.stopPrank();
        return sharesAfter - sharesBefore;
    }

    function _withdraw(address client, uint256 amount, address recipient) internal returns (uint256) {
        uint256 balanceBefore = dolaToken.balanceOf(recipient);
        vm.prank(client);
        vault.withdraw(address(dolaToken), amount, recipient);
        uint256 balanceAfter = dolaToken.balanceOf(recipient);
        return balanceAfter - balanceBefore;
    }

    function _simulateYield(uint256 yieldAmount) internal {
        autoDolaVault.simulateYield(yieldAmount);
        dolaToken.mint(address(autoDolaVault), yieldAmount);
    }

    // ============================================
    // CATEGORY 1: BASIC WITHDRAWAL ACCOUNTING
    // ============================================

    /**
     * @notice Test: Principal-only withdrawal returns exact deposit amount
     * @dev With no yield accrual, user should receive exactly what they deposited
     */
    function testBasicWithdrawal_PrincipalOnly() public {
        uint256 depositAmount = 1000 ether;

        // Deposit
        _deposit(client1, depositAmount, recipient1);

        // Verify balance
        uint256 balance = vault.balanceOf(address(dolaToken), recipient1);
        assertEq(balance, depositAmount, "Balance should match deposit amount");

        // Withdraw entire balance
        uint256 received = _withdraw(client1, depositAmount, recipient1);

        // Should receive exactly principal
        assertEq(received, depositAmount, "User should receive exact principal with no yield");
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 0, "Balance should be zero after full withdrawal");
    }

    /**
     * @notice Test: Balance updates correctly after withdrawal
     * @dev Balance tracking should be accurate throughout withdrawal lifecycle
     */
    function testBasicWithdrawal_BalanceUpdates() public {
        uint256 depositAmount = 5000 ether;
        uint256 withdrawAmount = 2000 ether;

        _deposit(client1, depositAmount, recipient1);

        uint256 balanceBefore = vault.balanceOf(address(dolaToken), recipient1);
        assertEq(balanceBefore, depositAmount, "Initial balance should match deposit");

        _withdraw(client1, withdrawAmount, recipient1);

        uint256 balanceAfter = vault.balanceOf(address(dolaToken), recipient1);
        assertEq(balanceAfter, depositAmount - withdrawAmount, "Balance should decrease by withdrawal amount");
    }

    /**
     * @notice Test: Multiple sequential withdrawals maintain accurate accounting
     * @dev Sequential withdrawals should correctly track remaining balance
     */
    function testBasicWithdrawal_SequentialWithdrawals() public {
        uint256 depositAmount = 10000 ether;

        _deposit(client1, depositAmount, recipient1);

        // First withdrawal
        uint256 withdraw1 = 3000 ether;
        _withdraw(client1, withdraw1, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 7000 ether, "Balance after first withdrawal");

        // Second withdrawal
        uint256 withdraw2 = 2500 ether;
        _withdraw(client1, withdraw2, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 4500 ether, "Balance after second withdrawal");

        // Third withdrawal
        uint256 withdraw3 = 1500 ether;
        _withdraw(client1, withdraw3, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 3000 ether, "Balance after third withdrawal");
    }

    /**
     * @notice Test: Partial withdrawal followed by full withdrawal of remainder
     * @dev Two-step withdrawal process should maintain accounting accuracy
     */
    function testBasicWithdrawal_PartialThenFull() public {
        uint256 depositAmount = 8000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Partial withdrawal
        uint256 partialAmount = 3000 ether;
        uint256 received1 = _withdraw(client1, partialAmount, recipient1);
        assertEq(received1, partialAmount, "Should receive partial amount");

        uint256 remainingBalance = vault.balanceOf(address(dolaToken), recipient1);
        assertEq(remainingBalance, 5000 ether, "Remaining balance should be correct");

        // Full withdrawal of remainder
        uint256 received2 = _withdraw(client1, remainingBalance, recipient1);
        assertEq(received2, remainingBalance, "Should receive remaining balance");
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 0, "Final balance should be zero");
    }

    /**
     * @notice Test: Share balance correctly reflects withdrawals
     * @dev Total shares in MainRewarder should decrease proportionally with withdrawals
     */
    function testBasicWithdrawal_ShareBalanceAccuracy() public {
        uint256 depositAmount = 6000 ether;

        _deposit(client1, depositAmount, recipient1);

        uint256 sharesBefore = mainRewarder.balanceOf(address(vault));
        assertTrue(sharesBefore > 0, "Should have shares staked");

        uint256 withdrawAmount = 2000 ether;
        _withdraw(client1, withdrawAmount, recipient1);

        uint256 sharesAfter = mainRewarder.balanceOf(address(vault));

        // Shares should decrease proportionally (roughly 1/3 for 2000/6000)
        uint256 expectedSharesRemaining = (sharesBefore * 4000) / 6000;
        assertApproxEqRel(sharesAfter, expectedSharesRemaining, 0.01e18, "Shares should decrease proportionally");
    }

    // ============================================
    // CATEGORY 2: YIELD EXCLUSION TESTS
    // ============================================

    /**
     * @notice Test: User cannot withdraw more than principal after yield accrual
     * @dev Even with yield growth, user can only withdraw their deposited principal
     */
    function testYieldExclusion_CannotWithdrawYield() public {
        uint256 depositAmount = 5000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Accrue yield
        uint256 yieldAmount = 500 ether;
        _simulateYield(yieldAmount);

        // User balance should still be principal only
        uint256 balance = vault.balanceOf(address(dolaToken), recipient1);
        assertEq(balance, depositAmount, "Balance should remain at principal despite yield");

        // Attempting to withdraw more than principal should revert
        vm.expectRevert("AutoDolaYieldStrategy: insufficient balance");
        vm.prank(client1);
        vault.withdraw(address(dolaToken), depositAmount + 1, recipient1);
    }

    /**
     * @notice Test: Yield remains in vault after user withdrawal
     * @dev Withdrawn shares' yield portion should be re-staked, not given to user
     */
    // REMOVED: testYieldExclusion_YieldRemainsInVault
    // No longer relevant - yield is proportionally distributed, not retained

    /**
     * @notice Test: Multiple users' withdrawals don't allow yield extraction
     * @dev Each user can only withdraw their principal, yield is never distributed
     */
    function testProportionalDistribution_MultipleUsers() public {
        uint256 deposit1 = 3000 ether;
        uint256 deposit2 = 7000 ether;

        _deposit(client1, deposit1, recipient1);
        _deposit(client2, deposit2, recipient2);

        // Accrue yield
        uint256 yieldAmount = 2000 ether;
        _simulateYield(yieldAmount);

        // Total: 10000 principal + 2000 yield = 12000 total value
        // User 1 owns 30% (3000/10000), User 2 owns 70% (7000/10000)

        // First user withdraws all principal
        uint256 received1 = _withdraw(client1, deposit1, recipient1);
        // User 1 receives 30% of 12000 = 3600 (3000 principal + 600 yield)
        uint256 expected1 = deposit1 + ((yieldAmount * deposit1) / (deposit1 + deposit2));
        assertEq(received1, expected1, "User 1 receives principal + proportional yield");

        // Second user withdraws all principal
        uint256 received2 = _withdraw(client2, deposit2, recipient2);
        // User 2 receives 70% of remaining ~8400 = ~8400 (7000 principal + 1400 yield)
        // Note: approximate due to rounding from first withdrawal
        assertApproxEqRel(received2, 8400 ether, 0.01e18, "User 2 receives principal + remaining yield");

        // All value distributed - vault should be empty
        uint256 remainingShares = mainRewarder.balanceOf(address(vault));
        assertEq(remainingShares, 0, "All shares distributed");
    }

    /**
     * @notice Test: Re-depositing after partial withdrawal doesn't unlock previous yield
     * @dev New deposits should not grant access to previously accrued yield
     */
    function testYieldExclusion_ReDepositNoYieldAccess() public {
        uint256 initialDeposit = 5000 ether;

        _deposit(client1, initialDeposit, recipient1);

        // Accrue yield
        uint256 yieldAmount = 1000 ether;
        _simulateYield(yieldAmount);

        // Partial withdrawal
        uint256 withdrawAmount = 2000 ether;
        _withdraw(client1, withdrawAmount, recipient1);

        uint256 balanceAfterWithdraw = vault.balanceOf(address(dolaToken), recipient1);
        assertEq(balanceAfterWithdraw, 3000 ether, "Balance after withdrawal");

        // Re-deposit
        uint256 reDepositAmount = 4000 ether;
        _deposit(client1, reDepositAmount, recipient1);

        // User balance should be sum of remaining + re-deposit, NOT including yield
        uint256 expectedBalance = balanceAfterWithdraw + reDepositAmount;
        assertEq(vault.balanceOf(address(dolaToken), recipient1), expectedBalance,
            "Balance should be principal only, no yield access from re-deposit");
    }

    /**
     * @notice Test: Sequential yield accruals - proportional distribution works correctly
     * @dev Multiple yield events should all be proportionally distributed to users
     */
    function testProportionalDistribution_SequentialYieldAccruals() public {
        uint256 depositAmount = 8000 ether;

        _deposit(client1, depositAmount, recipient1);

        // First yield event
        _simulateYield(500 ether);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), depositAmount, "Balance tracking unchanged after first yield");

        // Second yield event
        _simulateYield(300 ether);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), depositAmount, "Balance tracking unchanged after second yield");

        // Third yield event
        _simulateYield(700 ether);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), depositAmount, "Balance tracking unchanged after third yield");

        // User withdraws principal but receives principal + ALL proportional yield
        uint256 received = _withdraw(client1, depositAmount, recipient1);
        uint256 totalYield = 500 ether + 300 ether + 700 ether; // 1500 ether
        uint256 expectedReceived = depositAmount + totalYield; // 9500 ether
        assertEq(received, expectedReceived, "User receives principal + all proportional yield");

        // All value distributed - vault empty
        uint256 remainingShares = mainRewarder.balanceOf(address(vault));
        assertEq(remainingShares, 0, "All value distributed");
    }

    // ============================================
    // CATEGORY 3: LEFTOVERSHARES CALCULATION ACCURACY
    // ============================================

    /**
     * @notice Test: LeftoverShares calculation matches actual vault balance
     * @dev EXPECTED TO FAIL - This test exposes the line 228 bug
     *      The internal calculation may not match actual shares remaining in vault
     */
    function testLeftoverShares_MatchesVaultBalance() public {
        uint256 depositAmount = 10000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Accrue yield to create non-1:1 ratio
        uint256 yieldAmount = 837 ether; // Prime number for rounding
        _simulateYield(yieldAmount);

        // Partial withdrawal
        uint256 withdrawAmount = 3333 ether; // Non-round number

        uint256 vaultSharesBefore = autoDolaVault.balanceOf(address(vault));
        _withdraw(client1, withdrawAmount, recipient1);
        uint256 vaultSharesAfter = autoDolaVault.balanceOf(address(vault));

        // The shares burned from autoDOLA vault should match internal calculation
        uint256 totalStakedShares = mainRewarder.balanceOf(address(vault));

        // CRITICAL ASSERTION: Vault balance should match staked shares
        // This may fail due to rounding in leftoverShares calculation (line 228)
        assertEq(vaultSharesAfter, totalStakedShares,
            "AutoDOLA vault balance must match MainRewarder staked balance - leftoverShares calculation error");
    }

    /**
     * @notice Test: Query vault for remaining shares vs internal calculation
     * @dev EXPECTED TO FAIL - Direct comparison between vault query and internal calc
     *      Exposes any discrepancy in the leftoverShares math
     */
    function testLeftoverShares_VaultQueryVsInternalCalc() public {
        uint256 depositAmount = 15000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Create complex ratio with yield
        uint256 yieldAmount = 1789 ether; // Large prime
        _simulateYield(yieldAmount);

        // Withdraw amount that causes significant share calculations
        uint256 withdrawAmount = 7654 ether;

        // Get vault state before withdrawal
        uint256 totalSharesInMainRewarder = mainRewarder.balanceOf(address(vault));
        uint256 totalSharesInVaultBefore = autoDolaVault.balanceOf(address(vault));

        _withdraw(client1, withdrawAmount, recipient1);

        // Check if vault and mainRewarder share counts are in sync
        uint256 totalSharesInMainRewarderAfter = mainRewarder.balanceOf(address(vault));
        uint256 totalSharesInVaultAfter = autoDolaVault.balanceOf(address(vault));

        // CRITICAL: These should be exactly equal
        // Any discrepancy indicates leftoverShares calculation error
        assertEq(totalSharesInVaultAfter, totalSharesInMainRewarderAfter,
            "Vault share balance must exactly match MainRewarder staked balance");
    }

    /**
     * @notice Test: Rounding errors in leftoverShares calculation
     * @dev EXPECTED TO FAIL - Specifically targets rounding edge cases
     */
    function testLeftoverShares_RoundingErrors() public {
        uint256 depositAmount = 1e18 + 1; // Just over 1 ether

        _deposit(client1, depositAmount, recipient1);

        // Small yield to create fractional ratios
        uint256 yieldAmount = 7; // Very small yield
        _simulateYield(yieldAmount);

        // Withdraw amount that causes precision loss
        uint256 withdrawAmount = 333333333333333333; // ~0.333 ether

        uint256 vaultSharesBefore = autoDolaVault.balanceOf(address(vault));
        uint256 stakedSharesBefore = mainRewarder.balanceOf(address(vault));

        _withdraw(client1, withdrawAmount, recipient1);

        uint256 vaultSharesAfter = autoDolaVault.balanceOf(address(vault));
        uint256 stakedSharesAfter = mainRewarder.balanceOf(address(vault));

        // Even with rounding, vault and staked shares must be exactly equal
        assertEq(vaultSharesAfter, stakedSharesAfter,
            "Rounding errors in leftoverShares calculation cause vault/staked mismatch");
    }

    // REMOVED: testLeftoverShares_YieldExclusionAccuracy
    // No longer relevant - yield exclusion eliminated in proportional distribution

    /**
     * @notice Test: LeftoverShares calculation with multiple concurrent users
     * @dev EXPECTED TO FAIL - Complex multi-user scenario may expose calculation errors
     */
    function testLeftoverShares_MultipleUsers() public {
        uint256 deposit1 = 8000 ether;
        uint256 deposit2 = 12000 ether;

        _deposit(client1, deposit1, recipient1);
        _deposit(client2, deposit2, recipient2);

        // Accrue yield
        uint256 yieldAmount = 3000 ether;
        _simulateYield(yieldAmount);

        // Both users make partial withdrawals
        _withdraw(client1, 3000 ether, recipient1);

        // Check consistency
        uint256 vaultSharesAfterFirst = autoDolaVault.balanceOf(address(vault));
        uint256 stakedSharesAfterFirst = mainRewarder.balanceOf(address(vault));
        assertEq(vaultSharesAfterFirst, stakedSharesAfterFirst, "Mismatch after first user withdrawal");

        _withdraw(client2, 5000 ether, recipient2);

        // Check consistency again
        uint256 vaultSharesAfterSecond = autoDolaVault.balanceOf(address(vault));
        uint256 stakedSharesAfterSecond = mainRewarder.balanceOf(address(vault));
        assertEq(vaultSharesAfterSecond, stakedSharesAfterSecond, "Mismatch after second user withdrawal");
    }

    // ============================================
    // CATEGORY 4: DUST AND ROUNDING EDGE CASES
    // ============================================

    /**
     * @notice Test: Withdrawal leaving dust amount in vault (<1 wei)
     * @dev Precision handling should not cause share accounting errors with dust
     */
    function testDust_WithdrawalLeavingDust() public {
        uint256 depositAmount = 1234567890123456789; // ~1.234 ether with precision

        _deposit(client1, depositAmount, recipient1);

        // Small yield
        _simulateYield(11);

        // Withdraw most of it, leaving dust
        uint256 withdrawAmount = 1234567890123456788;
        _withdraw(client1, withdrawAmount, recipient1);

        // Vault and staked shares should still match exactly
        uint256 vaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(vaultShares, stakedShares, "Dust amounts should not cause share mismatch");
    }

    /**
     * @notice Test: Withdrawal of minimal amount (dust withdrawal)
     * @dev Withdrawing tiny amounts should maintain accounting accuracy
     */
    function testDust_MinimalWithdrawal() public {
        uint256 depositAmount = 1000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Withdraw 1 wei
        uint256 withdrawAmount = 1;
        uint256 received = _withdraw(client1, withdrawAmount, recipient1);

        // Should receive the dust amount
        assertEq(received, withdrawAmount, "Should receive dust amount");

        // Shares should still be consistent
        uint256 vaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(vaultShares, stakedShares, "Dust withdrawal should not break share accounting");
    }

    /**
     * @notice Test: Rounding in proportional distribution is fair
     * @dev Proportional distribution includes yield based on ownership share
     */
    function testDust_RoundingWithProportionalDistribution() public {
        uint256 depositAmount = 10000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Prime number yield for rounding
        uint256 yieldAmount = 997 ether;
        _simulateYield(yieldAmount);

        // Total vault: 10000 + 997 = 10997
        // Withdraw 3333 principal (33.33% of principal)
        // Should receive ~33.33% of total vault = ~3665.3 DOLA
        uint256 withdrawAmount = 3333 ether;
        uint256 received = _withdraw(client1, withdrawAmount, recipient1);

        // User receives proportional share (principal + yield portion)
        // Expected: (3333 / 10000) * 10997 = 3665.3001 ether
        uint256 expectedMin = 3665 ether;
        uint256 expectedMax = 3666 ether;
        assertGe(received, expectedMin, "Should receive at least principal + proportional yield");
        assertLe(received, expectedMax, "Rounding should be reasonable");

        // User balance tracking decreases by requested amount
        uint256 remainingBalance = vault.balanceOf(address(dolaToken), recipient1);
        assertEq(remainingBalance, depositAmount - withdrawAmount, "Balance tracking decreases by requested amount");
    }

    /**
     * @notice Test: Fractional share calculations maintain yield exclusion
     * @dev Complex fractional calculations should preserve yield exclusion
     */
    function testDust_FractionalShareCalculations() public {
        uint256 depositAmount = 7777777777777777777; // Complex fraction

        _deposit(client1, depositAmount, recipient1);

        // Yield that creates fractional ratio
        uint256 yieldAmount = 1111111111111111111;
        _simulateYield(yieldAmount);

        // Withdraw fraction
        uint256 withdrawAmount = 2222222222222222222;
        _withdraw(client1, withdrawAmount, recipient1);

        // Vault and staked shares must match
        uint256 vaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(vaultShares, stakedShares, "Fractional calculations should not break share accounting");
    }

    /**
     * @notice Test: Precision loss accumulation across multiple operations
     * @dev Multiple withdrawals should not accumulate rounding errors
     */
    function testDust_PrecisionLossAccumulation() public {
        uint256 depositAmount = 9999999999999999999; // ~10 ether - 1 wei

        _deposit(client1, depositAmount, recipient1);

        // Multiple small yields
        for (uint256 i = 0; i < 5; i++) {
            _simulateYield(7);
        }

        // Multiple small withdrawals
        for (uint256 i = 0; i < 10; i++) {
            _withdraw(client1, 333333333333333333, recipient1); // ~0.333 ether each
        }

        // After many operations, shares should still match
        uint256 vaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(vaultShares, stakedShares, "Precision loss should not accumulate across operations");
    }

    // ============================================
    // CATEGORY 5: LARGE AMOUNT TESTS
    // ============================================

    /**
     * @notice Test: Large deposit withdrawal accounting
     * @dev Very large amounts should maintain accurate accounting
     */
    function testLargeAmounts_LargeDeposit() public {
        uint256 largeAmount = 1000000000 ether; // 1 billion DOLA

        _deposit(client1, largeAmount, recipient1);

        // Verify balance
        assertEq(vault.balanceOf(address(dolaToken), recipient1), largeAmount, "Large deposit balance");

        // Withdraw half
        uint256 withdrawAmount = 500000000 ether;
        uint256 received = _withdraw(client1, withdrawAmount, recipient1);

        assertEq(received, withdrawAmount, "Should receive exact amount for large withdrawal");
        assertEq(vault.balanceOf(address(dolaToken), recipient1), largeAmount - withdrawAmount,
            "Large amount accounting should be accurate");
    }

    /**
     * @notice Test: Large yield accrual proportional distribution
     * @dev Massive yield growth is correctly distributed proportionally
     */
    function testLargeAmounts_LargeYieldAccrual() public {
        uint256 depositAmount = 10000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Massive yield (100x deposit)
        uint256 massiveYield = 1000000 ether;
        _simulateYield(massiveYield);

        // Balance tracking still shows principal only
        assertEq(vault.balanceOf(address(dolaToken), recipient1), depositAmount,
            "Balance tracking shows principal despite massive yield");

        // User withdraws and receives principal + ALL yield (100% ownership)
        uint256 received = _withdraw(client1, depositAmount, recipient1);
        uint256 expectedReceived = depositAmount + massiveYield; // 1,010,000 ether
        assertEq(received, expectedReceived, "Should receive principal + massive proportional yield");

        // All value distributed - vault empty
        uint256 remainingValue = autoDolaVault.convertToAssets(mainRewarder.balanceOf(address(vault)));
        assertEq(remainingValue, 0, "All value distributed");
    }

    /**
     * @notice Test: High precision amounts maintain accurate accounting
     * @dev Full precision amounts should not cause calculation errors
     */
    function testLargeAmounts_HighPrecision() public {
        uint256 preciseAmount = 123456789012345678901234; // Very precise large number

        _deposit(client1, preciseAmount, recipient1);

        // Add precise yield
        uint256 preciseYield = 98765432109876543210987;
        _simulateYield(preciseYield);

        // Withdraw precise amount - with new logic this succeeds (partial withdrawal)
        uint256 preciseWithdraw = 45678901234567890123456;
        _withdraw(client1, preciseWithdraw, recipient1);

        // Should be able to withdraw remaining principal
        uint256 remaining = preciseAmount - preciseWithdraw;
        _withdraw(client1, remaining, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 0, "Should fully withdraw precise amount");
    }

    /**
     * @notice Test: Multiple large operations don't accumulate errors
     * @dev Sequential large operations should maintain accuracy
     */
    function testLargeAmounts_MultipleOperations() public {
        // Multiple large deposits
        _deposit(client1, 100000 ether, recipient1);
        _deposit(client1, 200000 ether, recipient1);
        _deposit(client1, 300000 ether, recipient1);

        uint256 totalDeposited = 600000 ether;
        assertEq(vault.balanceOf(address(dolaToken), recipient1), totalDeposited, "Total deposited");

        // Large yield events
        _simulateYield(50000 ether);
        _simulateYield(75000 ether);

        // Multiple large withdrawals
        _withdraw(client1, 150000 ether, recipient1);
        _withdraw(client1, 200000 ether, recipient1);

        assertEq(vault.balanceOf(address(dolaToken), recipient1), 250000 ether,
            "Balance should be accurate after multiple large operations");

        // Shares should still match
        uint256 vaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(vaultShares, stakedShares, "Large operations should not break share accounting");
    }

    // ============================================
    // CATEGORY 6: PARTIAL WITHDRAWAL TESTS
    // ============================================

    /**
     * @notice Test: 50% partial withdrawal maintains correct remaining balance
     * @dev Half withdrawal should leave exactly half the balance
     */
    function testPartialWithdrawal_FiftyPercent() public {
        uint256 depositAmount = 10000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Withdraw exactly half
        uint256 halfAmount = 5000 ether;
        uint256 received = _withdraw(client1, halfAmount, recipient1);

        assertEq(received, halfAmount, "Should receive half amount");
        assertEq(vault.balanceOf(address(dolaToken), recipient1), halfAmount,
            "Remaining balance should be exactly half");
    }

    /**
     * @notice Test: Series of small partial withdrawals (10% each)
     * @dev Sequential small withdrawals should maintain accounting accuracy
     */
    function testPartialWithdrawal_SeriesOfSmallWithdrawals() public {
        uint256 depositAmount = 10000 ether;

        _deposit(client1, depositAmount, recipient1);

        uint256 tenPercent = 1000 ether;

        // Withdraw 10% five times
        for (uint256 i = 0; i < 5; i++) {
            _withdraw(client1, tenPercent, recipient1);
            uint256 expectedRemaining = depositAmount - (tenPercent * (i + 1));
            assertEq(vault.balanceOf(address(dolaToken), recipient1), expectedRemaining,
                "Balance should decrease by 10% each time");
        }

        // Final balance should be 50%
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 5000 ether, "Final balance should be 50%");
    }

    /**
     * @notice Test: Partial withdrawal with yield accrual between withdrawals
     * @dev Yield between withdrawals should not affect principal withdrawal amounts
     */
    function testPartialWithdrawal_WithYieldBetween() public {
        uint256 depositAmount = 8000 ether;

        _deposit(client1, depositAmount, recipient1);

        // First partial withdrawal
        _withdraw(client1, 2000 ether, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 6000 ether, "After first withdrawal");

        // Yield accrues
        _simulateYield(500 ether);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 6000 ether,
            "Yield should not change user balance");

        // Second partial withdrawal
        _withdraw(client1, 3000 ether, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 3000 ether, "After second withdrawal");

        // More yield
        _simulateYield(300 ether);

        // Final withdrawal
        _withdraw(client1, 3000 ether, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 0, "Final balance should be zero");
    }

    /**
     * @notice Test: Partial withdrawal includes proportional yield
     * @dev Withdrawing portion of principal distributes proportional yield
     */
    function testPartialWithdrawal_IncludesProportionalYield() public {
        uint256 depositAmount = 10000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Large yield
        uint256 yieldAmount = 5000 ether;
        _simulateYield(yieldAmount);

        // Total vault: 10000 principal + 5000 yield = 15000
        // Partial withdrawal (50% of principal)
        uint256 received = _withdraw(client1, 5000 ether, recipient1);

        // User owns 100% of vault, withdraws 50% of principal
        // Should receive 50% of total value = 50% of 15000 = 7500
        // That's 5000 principal + 2500 yield
        uint256 expectedReceived = 7500 ether;
        assertEq(received, expectedReceived, "Should receive principal + proportional yield");

        // Remaining balance tracking is still 50% of principal
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 5000 ether,
            "Remaining balance tracking is principal only");

        // Remaining vault value ~7500 (half of original total)
        uint256 totalValue = autoDolaVault.convertToAssets(mainRewarder.balanceOf(address(vault)));
        assertApproxEqRel(totalValue, 7500 ether, 0.02e18, "Remaining value is half of total");
    }

    // ============================================
    // CATEGORY 7: FULL WITHDRAWAL TESTS
    // ============================================

    /**
     * @notice Test: Full withdrawal after yield accrual leaves zero user balance
     * @dev Complete withdrawal should result in zero balance, yield stays in vault
     */
    function testFullWithdrawal_AfterYield() public {
        uint256 depositAmount = 15000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Accrue yield
        uint256 yieldAmount = 3000 ether;
        _simulateYield(yieldAmount);

        // Full withdrawal
        uint256 received = _withdraw(client1, depositAmount, recipient1);

        // NEW BEHAVIOR: Proportional distribution gives users principal + yield
        // User owns 100% of vault (15000/15000 principal), total value = 18000
        // User receives 100% of 18000 = 18000 DOLA
        uint256 expectedReceived = depositAmount + yieldAmount; // 18000 ether
        assertEq(received, expectedReceived, "Should receive principal + proportional yield");
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 0, "Balance should be zero after full withdrawal");

        // No yield remains - all distributed proportionally
        uint256 remainingValue = autoDolaVault.convertToAssets(mainRewarder.balanceOf(address(vault)));
        assertEq(remainingValue, 0, "All funds distributed");
    }

    /**
     * @notice Test: Full withdrawal includes proportional yield
     * @dev User receives principal plus their proportional share of accrued yield
     */
    function testFullWithdrawal_IncludesProportionalYield() public {
        uint256 depositAmount = 7500 ether;
        uint256 yieldAmount = 10000 ether;

        _deposit(client1, depositAmount, recipient1);

        // Large yield
        _simulateYield(yieldAmount);

        // Get recipient balance before
        uint256 balanceBefore = dolaToken.balanceOf(recipient1);

        // Full withdrawal
        _withdraw(client1, depositAmount, recipient1);

        // Check exact received amount
        uint256 balanceAfter = dolaToken.balanceOf(recipient1);
        uint256 received = balanceAfter - balanceBefore;

        // Proportional distribution: user owns 100% of vault (7500/7500)
        // Total vault value = 7500 principal + 10000 yield = 17500
        // User receives 100% = 17500 DOLA
        uint256 expectedReceived = depositAmount + yieldAmount; // 17500 ether
        assertEq(received, expectedReceived, "Should receive principal + proportional yield");
    }

    // REMOVED: testFullWithdrawal_LeftoverSharesCalculation
    // No longer relevant - proportional distribution eliminates leftover shares concept

    // REMOVED: testFullWithdrawal_ReStakingLeftoverShares
    // No longer relevant - re-staking mechanism is obsolete under proportional distribution

    // ============================================
    // CATEGORY 8: RE-STAKING BEHAVIOR TESTS
    // ============================================

    /**
     * @notice Test: LeftoverShares are correctly re-staked in mainRewarder
     * @dev Every withdrawal should re-stake leftover shares representing excluded yield
     */
    function testReStaking_LeftoverSharesReStaked() public {
        uint256 depositAmount = 10000 ether;

        _deposit(client1, depositAmount, recipient1);

        uint256 yieldAmount = 1000 ether;
        _simulateYield(yieldAmount);

        // Partial withdrawal
        uint256 withdrawAmount = 5000 ether;

        uint256 stakedBefore = mainRewarder.balanceOf(address(vault));
        _withdraw(client1, withdrawAmount, recipient1);
        uint256 stakedAfter = mainRewarder.balanceOf(address(vault));

        // Should still have staked shares after withdrawal
        assertTrue(stakedAfter > 0, "Should have re-staked shares");

        // Staked shares should match vault shares
        uint256 vaultShares = autoDolaVault.balanceOf(address(vault));
        assertEq(vaultShares, stakedAfter, "Re-staked shares should match vault balance");
    }

    /**
     * @notice Test: Re-staking happens atomically with withdrawal
     * @dev There should be no intermediate state where shares are unstaked but not re-staked
     */
    function testReStaking_Atomicity() public {
        uint256 depositAmount = 8000 ether;

        _deposit(client1, depositAmount, recipient1);

        _simulateYield(800 ether);

        // Before withdrawal, all shares are staked
        uint256 vaultSharesBefore = autoDolaVault.balanceOf(address(vault));
        uint256 stakedSharesBefore = mainRewarder.balanceOf(address(vault));
        assertEq(vaultSharesBefore, stakedSharesBefore, "Pre-withdrawal: vault and staked match");

        // Perform withdrawal
        _withdraw(client1, 3000 ether, recipient1);

        // After withdrawal, all shares should still be staked (including leftovers)
        uint256 vaultSharesAfter = autoDolaVault.balanceOf(address(vault));
        uint256 stakedSharesAfter = mainRewarder.balanceOf(address(vault));
        assertEq(vaultSharesAfter, stakedSharesAfter, "Post-withdrawal: vault and staked match (atomic re-stake)");
    }

    // REMOVED: testReStaking_AmountMatchesExcludedYield
    // No longer relevant - excluded yield concept removed in proportional distribution

    // REMOVED: testReStaking_NoInterferenceWithWithdrawal
    // No longer relevant - re-staking mechanism obsolete

    // ============================================
    // CATEGORY 9: SEQUENTIAL DEPOSIT/WITHDRAWAL CYCLES
    // ============================================

    /**
     * @notice Test: Deposit → Withdraw → Deposit → Withdraw cycle maintains accuracy
     * @dev Multiple cycles should maintain accounting integrity
     */
    function testCycles_DepositWithdrawCycle() public {
        // First cycle
        _deposit(client1, 5000 ether, recipient1);
        _withdraw(client1, 3000 ether, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 2000 ether, "After cycle 1");

        // Second cycle
        _deposit(client1, 4000 ether, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 6000 ether, "After cycle 2 deposit");
        _withdraw(client1, 2000 ether, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 4000 ether, "After cycle 2");

        // Third cycle
        _deposit(client1, 3000 ether, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 7000 ether, "After cycle 3 deposit");
        _withdraw(client1, 5000 ether, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 2000 ether, "After cycle 3");

        // Shares should still be consistent
        uint256 vaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(vaultShares, stakedShares, "Multiple cycles should not break share accounting");
    }

    /**
     * @notice Test: Multiple users cycling deposits/withdrawals don't interfere
     * @dev Two users performing concurrent cycles should have isolated accounting
     */
    function testCycles_MultipleUsersCycles() public {
        // User 1: First cycle
        _deposit(client1, 4000 ether, recipient1);
        _withdraw(client1, 1000 ether, recipient1);

        // User 2: First cycle
        _deposit(client2, 6000 ether, recipient2);
        _withdraw(client2, 2000 ether, recipient2);

        // Verify balances are independent
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 3000 ether, "User 1 balance");
        assertEq(vault.balanceOf(address(dolaToken), recipient2), 4000 ether, "User 2 balance");

        // User 1: Second cycle
        _deposit(client1, 2000 ether, recipient1);
        _withdraw(client1, 4000 ether, recipient1);

        // User 2: Second cycle
        _deposit(client2, 3000 ether, recipient2);
        _withdraw(client2, 5000 ether, recipient2);

        // Verify final balances
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 1000 ether, "User 1 final balance");
        assertEq(vault.balanceOf(address(dolaToken), recipient2), 2000 ether, "User 2 final balance");

        // Shares should be consistent
        uint256 vaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(vaultShares, stakedShares, "Multi-user cycles should not break share accounting");
    }

    /**
     * @notice Test: Yield distribution across multiple cycles
     * @dev Yield from all cycles is distributed proportionally
     */
    function testCycles_YieldDistributedAcrossCycles() public {
        // Cycle 1: Deposit and accrue yield
        _deposit(client1, 5000 ether, recipient1);
        _simulateYield(1000 ether);

        // Total: 6000 ether
        // Partial withdrawal (60% of principal) receives proportional share
        // Expected: (3000/5000) * 6000 = 3600 ether
        uint256 received1 = _withdraw(client1, 3000 ether, recipient1);
        assertEq(received1, 3600 ether, "First withdrawal: principal + proportional yield");
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 2000 ether, "After first withdrawal");

        // Cycle 2: New deposit and more yield
        _deposit(client1, 4000 ether, recipient1);
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 6000 ether, "After second deposit");

        _simulateYield(500 ether);

        // Balance tracking unchanged by yield
        assertEq(vault.balanceOf(address(dolaToken), recipient1), 6000 ether,
            "Balance tracking unchanged by yield in second cycle");

        // Full withdrawal receives all remaining value
        // Previous withdrawal: 3600 out of 6000 total, leaving ~2400
        // New deposit: +4000, new yield: +500
        // Total remaining: ~2400 + 4000 + 500 = ~6900 ether
        uint256 received2 = _withdraw(client1, 6000 ether, recipient1);
        assertApproxEqRel(received2, 6900 ether, 0.01e18, "Second withdrawal: principal + all remaining yield");

        // All value distributed - vault empty
        uint256 remainingValue = autoDolaVault.convertToAssets(mainRewarder.balanceOf(address(vault)));
        assertEq(remainingValue, 0, "All value distributed");
    }

    /**
     * @notice Test: Balance tracking remains accurate across many cycles
     * @dev Extensive cycling should not drift accounting accuracy
     */
    function testCycles_ManyConsecutiveCycles() public {
        uint256 cycleCount = 10;

        for (uint256 i = 0; i < cycleCount; i++) {
            // Deposit varying amounts
            uint256 depositAmount = (i + 1) * 1000 ether;
            _deposit(client1, depositAmount, recipient1);

            // Add some yield each cycle
            _simulateYield((i + 1) * 100 ether);

            // Withdraw half
            uint256 withdrawAmount = depositAmount / 2;
            _withdraw(client1, withdrawAmount, recipient1);
        }

        // Calculate expected final balance
        uint256 expectedBalance = 0;
        for (uint256 i = 0; i < cycleCount; i++) {
            expectedBalance += ((i + 1) * 1000 ether) / 2;
        }

        assertEq(vault.balanceOf(address(dolaToken), recipient1), expectedBalance,
            "Balance should be accurate after many cycles");

        // Shares should be consistent
        uint256 vaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(vaultShares, stakedShares, "Many cycles should not break share accounting");
    }
}
