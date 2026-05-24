// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "../mocks/MockERC4626Vault.sol";

/**
 * @title ERC4626YieldStrategyTest
 * @notice Comprehensive unit tests for ERC4626YieldStrategy
 * @dev Covers deposit/withdraw tracking, yield distribution, rounding, pause behavior,
 *      access control, owner spoof functions, emergency withdraw, totalWithdrawal two-phase,
 *      fee-charging vaults, and edge cases.
 */
contract ERC4626YieldStrategyTest is Test {
    ERC4626YieldStrategy strategy;
    MockERC20 underlyingToken;
    MockERC4626Vault erc4626Vault;

    address owner = address(0x1234);
    address client = address(0x5678);
    address pauser = address(0x9ABC);
    address user1 = address(0xDEF0);
    address user2 = address(0x1357);
    address user3 = address(0x2468);
    address withdrawer = address(0xABCD);
    address randomUser = address(0xBEEF);

    uint256 constant INITIAL_TOKEN_SUPPLY = 10_000_000e18;

    function setUp() public {
        // Deploy mock tokens
        underlyingToken = new MockERC20("Underlying", "UNDERLYING", 18);

        // Deploy mock ERC4626 vault
        erc4626Vault = new MockERC4626Vault("Vault Shares", "vUNDERLYING", address(underlyingToken));

        // Deploy the strategy
        vm.prank(owner);
        strategy = new ERC4626YieldStrategy(owner, address(underlyingToken), address(erc4626Vault));

        // Mint tokens
        underlyingToken.mint(client, INITIAL_TOKEN_SUPPLY);
        underlyingToken.mint(owner, INITIAL_TOKEN_SUPPLY);

        // Authorize client, withdrawer, pauser
        vm.startPrank(owner);
        strategy.setClient(client, true);
        strategy.setWithdrawer(withdrawer, true);
        strategy.setPauser(pauser);
        vm.stopPrank();

        // Approve strategy to spend client's tokens
        vm.prank(client);
        underlyingToken.approve(address(strategy), type(uint256).max);

        // Approve strategy to spend owner's tokens (for depositAsOwner)
        vm.prank(owner);
        underlyingToken.approve(address(strategy), type(uint256).max);
    }

    // ============ DEPOSIT TRACKING TESTS ============

    /// @notice Test single-user deposit and verify principal tracking
    function testSingleUserDeposit() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), depositAmount);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), depositAmount);
        assertGt(strategy.getTotalShares(), 0);
    }

    /// @notice Test multi-user deposits and verify independent principal tracking
    function testMultiUserDeposits() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;
        uint256 deposit3 = 3000e18;

        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), deposit1, user1);
        strategy.deposit(address(underlyingToken), deposit2, user2);
        strategy.deposit(address(underlyingToken), deposit3, user3);
        vm.stopPrank();

        assertEq(strategy.principalOf(address(underlyingToken), user1), deposit1);
        assertEq(strategy.principalOf(address(underlyingToken), user2), deposit2);
        assertEq(strategy.principalOf(address(underlyingToken), user3), deposit3);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), deposit1 + deposit2 + deposit3);
    }

    // ============ totalBalanceOf() TESTS ============

    /// @notice Test totalBalanceOf() with no yield equals principalOf()
    function testTotalBalanceOfNoYieldEqualsPrincipal() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        assertEq(
            strategy.totalBalanceOf(address(underlyingToken), user1),
            strategy.principalOf(address(underlyingToken), user1)
        );
        assertEq(strategy.totalBalanceOf(address(underlyingToken), user1), depositAmount);
    }

    /// @notice Test totalBalanceOf() increases after simulateYield() on mock vault
    function testTotalBalanceOfIncreasesWithYield() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        // Simulate 10% yield
        erc4626Vault.simulateYield(100e18);

        uint256 totalBalance = strategy.totalBalanceOf(address(underlyingToken), user1);
        uint256 principal = strategy.principalOf(address(underlyingToken), user1);

        assertGt(totalBalance, principal);
        assertApproxEqAbs(totalBalance, 1100e18, 1);
    }

    /// @notice Test proportional yield distribution across multiple depositors
    function testProportionalYieldDistribution() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 4000e18;

        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), deposit1, user1);
        strategy.deposit(address(underlyingToken), deposit2, user2);
        vm.stopPrank();

        // Simulate 50% yield (5000 total becomes 7500)
        erc4626Vault.simulateYield(2500e18);

        uint256 user1Total = strategy.totalBalanceOf(address(underlyingToken), user1);
        uint256 user2Total = strategy.totalBalanceOf(address(underlyingToken), user2);

        // User2 should have 4x user1's total balance
        assertApproxEqAbs(user2Total, user1Total * 4, 1);

        // Verify approximate values
        assertApproxEqAbs(user1Total, 1500e18, 1); // 1000 + 500
        assertApproxEqAbs(user2Total, 6000e18, 1); // 4000 + 2000
    }

    // ============ WITHDRAW TESTS ============

    /// @notice Test withdraw() returns correct amount and updates principal
    function testWithdrawUpdatesCorrectly() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 400e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        uint256 balanceBefore = underlyingToken.balanceOf(client);

        vm.prank(client);
        strategy.withdraw(address(underlyingToken), withdrawAmount, client);

        uint256 balanceAfter = underlyingToken.balanceOf(client);

        // Principal should decrease by requested amount
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount - withdrawAmount);
        // Client should have received tokens
        assertApproxEqAbs(balanceAfter - balanceBefore, withdrawAmount, 1);
    }

    /// @notice Test withdraw() rounding favors protocol (requested > received is OK)
    function testWithdrawRoundingFavorsProtocol() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Simulate some yield so share price changes
        erc4626Vault.simulateYield(100e18);

        uint256 withdrawAmount = 500e18;
        uint256 balanceBefore = underlyingToken.balanceOf(client);

        vm.prank(client);
        strategy.withdraw(address(underlyingToken), withdrawAmount, client);

        uint256 received = underlyingToken.balanceOf(client) - balanceBefore;

        // Principal decremented by requested amount (500), not received amount
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount - withdrawAmount);

        // Received should be <= requested (rounding favors protocol)
        assertLe(received, withdrawAmount);
    }

    /// @notice Test withdrawal capped to available principal (dust handling)
    function testWithdrawalCappedToPrincipal() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Attempt to withdraw more than deposited
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), depositAmount + 500e18, client);

        // Principal should be zero (capped to available)
        assertEq(strategy.principalOf(address(underlyingToken), client), 0);
    }

    // ============ _skimSurplus() SURPLUS EXTRACTION TESTS ============

    /// @notice Test _skimSurplus() only allows surplus extraction
    function testSkimSurplusOnlyAllowsSurplus() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Generate 10% yield (1000 tokens surplus)
        erc4626Vault.simulateYield(1000e18);

        uint256 principal = strategy.principalOf(address(underlyingToken), client);
        uint256 totalBalance = strategy.totalBalanceOf(address(underlyingToken), client);
        uint256 surplus = totalBalance - principal;

        // Withdraw 50% of surplus
        uint256 withdrawAmount = surplus / 2;
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), client, withdrawAmount, withdrawer);

        // Principal MUST NOT change
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount);
    }

    /// @notice Test _skimSurplus() reverts when amount exceeds surplus
    function testSkimSurplusRevertsWhenExceedsSurplus() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Generate small yield
        erc4626Vault.simulateYield(100e18);

        uint256 principal = strategy.principalOf(address(underlyingToken), client);
        uint256 totalBalance = strategy.totalBalanceOf(address(underlyingToken), client);
        uint256 surplus = totalBalance - principal;

        // Attempt to withdraw more than surplus
        vm.expectRevert("ERC4626YieldStrategy: amount exceeds available surplus, use totalWithdrawal() for principal");
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), client, surplus + 50e18, withdrawer);
    }

    /// @notice Test _skimSurplus() never modifies principal
    function testSkimSurplusNeverModifiesPrincipal() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        erc4626Vault.simulateYield(1000e18);

        uint256 principalBefore = strategy.principalOf(address(underlyingToken), client);

        // Multiple surplus withdrawals
        for (uint256 i = 0; i < 5; i++) {
            uint256 totalBalance = strategy.totalBalanceOf(address(underlyingToken), client);
            uint256 principal = strategy.principalOf(address(underlyingToken), client);
            uint256 surplus = totalBalance > principal ? totalBalance - principal : 0;

            if (surplus > 10e18) {
                uint256 withdrawAmount = surplus / 4;
                vm.prank(withdrawer);
                strategy.skimSurplus(address(underlyingToken), client, withdrawAmount, withdrawer);

                // Principal MUST NOT change
                assertEq(strategy.principalOf(address(underlyingToken), client), principalBefore);
            }
        }

        // Final check
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount);
    }

    // ============ EMERGENCY WITHDRAW TESTS ============

    /// @notice Test _emergencyWithdraw() works when NOT paused
    function testEmergencyWithdrawWorksWhenNotPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);

        vm.prank(owner);
        strategy.emergencyWithdraw(500e18);

        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore);
    }

    /// @notice Test _emergencyWithdraw() works when contract IS paused
    function testEmergencyWithdrawWorksWhenPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Pause the contract
        vm.prank(pauser);
        strategy.pause();

        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);

        // Emergency withdraw should still work when paused
        vm.prank(owner);
        strategy.emergencyWithdraw(500e18);

        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore);
    }

    // ============ TOTAL WITHDRAWAL TWO-PHASE TESTS ============

    /// @notice Test totalWithdrawal() two-phase flow (initiate + execute)
    function testTotalWithdrawalTwoPhaseFlow() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Phase 1: Initiate withdrawal
        vm.prank(owner);
        strategy.totalWithdrawal(address(underlyingToken), client);

        // Advance past waiting period (24 hours)
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);

        // Phase 2: Execute withdrawal
        vm.prank(owner);
        strategy.totalWithdrawal(address(underlyingToken), client);

        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore);

        // Client balance should be zeroed out
        assertEq(strategy.principalOf(address(underlyingToken), client), 0);
    }

    // ============ OWNER SPOOF FUNCTION TESTS ============

    /// @notice Test withdrawAsOwner() works for authorized owner
    function testWithdrawAsOwnerWorks() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        uint256 recipientBalanceBefore = underlyingToken.balanceOf(user2);

        // Owner withdraws from user1's balance, sending to user2
        vm.prank(owner);
        strategy.withdrawAsOwner(user1, user2, 500e18);

        uint256 recipientBalanceAfter = underlyingToken.balanceOf(user2);
        assertGt(recipientBalanceAfter, recipientBalanceBefore);
        assertEq(strategy.principalOf(address(underlyingToken), user1), 500e18);
    }

    /// @notice Test withdrawAsOwner() reverts for non-owner
    function testWithdrawAsOwnerRevertsForNonOwner() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        strategy.withdrawAsOwner(user1, user2, 500e18);
    }

    /// @notice Test depositAsOwner() works for authorized owner
    function testDepositAsOwnerWorks() public {
        uint256 depositAmount = 1000e18;

        vm.prank(owner);
        strategy.depositAsOwner(address(underlyingToken), depositAmount, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), depositAmount);
    }

    /// @notice Test depositAsOwner() reverts for non-owner
    function testDepositAsOwnerRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        strategy.depositAsOwner(address(underlyingToken), 1000e18, user1);
    }

    // ============ ACCESS CONTROL TESTS ============

    /// @notice Test deposit() reverts for unauthorized client
    function testDepositRevertsForUnauthorizedClient() public {
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(randomUser);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test withdraw() reverts for unauthorized client
    function testWithdrawRevertsForUnauthorizedClient() public {
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(randomUser);
        strategy.withdraw(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test deposit() reverts for wrong token
    function testDepositRevertsForWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);

        vm.expectRevert("ERC4626YieldStrategy: only underlying token supported");
        vm.prank(client);
        strategy.deposit(address(wrongToken), 1000e18, user1);
    }

    // ============ PAUSE BEHAVIOR TESTS ============

    /// @notice Test deposit() reverts when paused
    function testDepositRevertsWhenPaused() public {
        vm.prank(pauser);
        strategy.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test withdraw() reverts when paused
    function testWithdrawRevertsWhenPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        vm.prank(pauser);
        strategy.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), 500e18, client);
    }

    // ============ FEE-CHARGING VAULT TESTS ============

    /// @notice Test with fee-charging mock vault (entry fee deducts shares, principal still tracks input amount)
    /// @dev When a fee-charging vault takes 5%, a second depositor's shares are worth less
    ///      than their input because existing fee revenue dilutes new deposits.
    function testFeeChargingVault() public {
        // Set 5% entry fee on vault
        erc4626Vault.setFeeBps(500); // 5%

        // First deposit: user1 deposits 1000
        uint256 deposit1 = 1000e18;
        vm.prank(client);
        strategy.deposit(address(underlyingToken), deposit1, user1);

        // Principal should track the FULL deposit amount (1000), not post-fee
        assertEq(strategy.principalOf(address(underlyingToken), user1), deposit1);

        // Shares should be fewer than deposit amount (950 shares for 1000 assets)
        uint256 shares1 = strategy.getTotalShares();
        assertLt(shares1, deposit1, "Shares should be less than deposit due to fee");

        // Second deposit: user2 deposits 1000
        // At this point vault has 1000 total assets, 950 shares
        // user2 deposits 1000, effective = 950 (after 5% fee)
        // new shares = 950 * 950 / (1000 + 1000) = 950 * 950 / 2000 = 451.25 shares
        // But vault total assets becomes 2000, total supply = 950 + 451 = 1401
        uint256 deposit2 = 1000e18;
        vm.prank(client);
        strategy.deposit(address(underlyingToken), deposit2, user2);

        // Principal should track full deposit for user2
        assertEq(strategy.principalOf(address(underlyingToken), user2), deposit2);

        // Total deposited should be 2000
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), deposit1 + deposit2);

        // User2's totalBalanceOf should be less than their deposit due to fee dilution
        // because user1's fee revenue is baked into the share price
        uint256 user2Total = strategy.totalBalanceOf(address(underlyingToken), user2);
        // The fee impact means user2 effectively got fewer shares relative to the pool
        // This is the correct behavior — principal tracks input, but shares track post-fee value
        assertLe(user2Total, deposit2, "Fee-charging vault should reduce totalBalanceOf for second depositor");
    }

    // ============ ZERO-AMOUNT EDGE CASES ============

    /// @notice Test zero-amount deposit reverts
    function testZeroDepositReverts() public {
        vm.expectRevert("ERC4626YieldStrategy: amount must be greater than zero");
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 0, user1);
    }

    /// @notice Test zero-amount withdraw reverts
    function testZeroWithdrawReverts() public {
        vm.expectRevert("ERC4626YieldStrategy: amount must be greater than zero");
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), 0, user1);
    }

    // ============ balanceOf() BACKWARD COMPATIBILITY TESTS ============

    /// @notice Test balanceOf() returns same as principalOf() (backward compat)
    function testBalanceOfReturnsPrincipalOf() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        // Add yield to ensure they diverge from totalBalanceOf
        erc4626Vault.simulateYield(100e18);

        // balanceOf should return principal, not total
        assertEq(
            strategy.balanceOf(address(underlyingToken), user1), strategy.principalOf(address(underlyingToken), user1)
        );
        assertEq(strategy.balanceOf(address(underlyingToken), user1), depositAmount);
        assertLt(
            strategy.balanceOf(address(underlyingToken), user1),
            strategy.totalBalanceOf(address(underlyingToken), user1)
        );
    }

    // ============ VIEW FUNCTION TESTS ============

    function testUnderlyingReturnsCorrectAddress() public view {
        assertEq(strategy.underlying(), address(underlyingToken));
    }

    function testGetTotalDepositedTracksCorrectly() public {
        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        strategy.deposit(address(underlyingToken), 2000e18, user2);
        vm.stopPrank();

        assertEq(strategy.getTotalDeposited(address(underlyingToken)), 3000e18);
    }

    function testGetTotalSharesTracksCorrectly() public {
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);

        // Shares should be > 0 after deposit
        assertGt(strategy.getTotalShares(), 0);
    }

    // ============ OWNER SPOOF DOES NOT REQUIRE whenNotPaused ============

    /// @notice Verify withdrawAsOwner works when paused
    function testWithdrawAsOwnerWorksWhenPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        vm.prank(pauser);
        strategy.pause();

        // Should still work
        vm.prank(owner);
        strategy.withdrawAsOwner(user1, owner, 500e18);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 500e18);
    }

    /// @notice Verify depositAsOwner works when paused
    function testDepositAsOwnerWorksWhenPaused() public {
        vm.prank(pauser);
        strategy.pause();

        // Should still work
        vm.prank(owner);
        strategy.depositAsOwner(address(underlyingToken), 1000e18, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
    }

    // ============ NO SURPLUS SCENARIO ============

    /// @notice Test skimSurplus reverts when there is no surplus
    function testSkimSurplusRevertsWithNoSurplus() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // No yield generated
        vm.expectRevert("ERC4626YieldStrategy: amount exceeds available surplus, use totalWithdrawal() for principal");
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), client, 1e18, withdrawer);
    }

    // ============ VAULT APPRECIATION SCENARIO ============

    function testVaultAppreciationOverTime() public {
        uint256 deposit = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), deposit, user1);

        // Initial: no yield
        assertEq(strategy.totalBalanceOf(address(underlyingToken), user1), deposit);

        // First yield: +10%
        erc4626Vault.simulateYield(100e18);
        assertApproxEqAbs(strategy.totalBalanceOf(address(underlyingToken), user1), 1100e18, 1);

        // Second yield: another +10% on top (1100 + 110 = 1210)
        erc4626Vault.simulateYield(110e18);
        assertApproxEqAbs(strategy.totalBalanceOf(address(underlyingToken), user1), 1210e18, 1);

        // Principal never changes
        assertEq(strategy.principalOf(address(underlyingToken), user1), deposit);
    }

    // ============ SUM OF BALANCES EQUALS VAULT VALUE ============

    function testSumOfBalancesEqualsVaultValue() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;
        uint256 deposit3 = 3000e18;

        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), deposit1, user1);
        strategy.deposit(address(underlyingToken), deposit2, user2);
        strategy.deposit(address(underlyingToken), deposit3, user3);
        vm.stopPrank();

        // Add yield
        erc4626Vault.simulateYield(600e18);

        uint256 user1Total = strategy.totalBalanceOf(address(underlyingToken), user1);
        uint256 user2Total = strategy.totalBalanceOf(address(underlyingToken), user2);
        uint256 user3Total = strategy.totalBalanceOf(address(underlyingToken), user3);
        uint256 sumTotal = user1Total + user2Total + user3Total;

        // Get actual vault value
        uint256 totalShares = erc4626Vault.balanceOf(address(strategy));
        uint256 totalValue = erc4626Vault.convertToAssets(totalShares);

        // Sum should equal total vault value (within rounding tolerance)
        assertApproxEqAbs(sumTotal, totalValue, 3);
    }

    // ============ WITHDRAW EXACT SURPLUS ============

    function testWithdrawExactSurplusAmount() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        erc4626Vault.simulateYield(500e18);

        uint256 principal = strategy.principalOf(address(underlyingToken), client);
        uint256 totalBalance = strategy.totalBalanceOf(address(underlyingToken), client);
        uint256 surplus = totalBalance - principal;

        // Withdraw EXACTLY the surplus
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), client, surplus, withdrawer);

        // Principal unchanged
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount);

        // After withdrawing all surplus, totalBalanceOf should approx equal principal
        uint256 totalBalanceAfter = strategy.totalBalanceOf(address(underlyingToken), client);
        assertApproxEqAbs(totalBalanceAfter, principal, 1);
    }

    // ============ MULTIPLE USERS WITH DIFFERENT PRINCIPALS ============

    function testMultipleUsersWithDifferentPrincipals() public {
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = 500e18;
        deposits[1] = 1500e18;
        deposits[2] = 3000e18;

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        vm.startPrank(client);
        for (uint256 i = 0; i < users.length; i++) {
            strategy.deposit(address(underlyingToken), deposits[i], users[i]);
        }
        vm.stopPrank();

        // Add 40% yield (5000 total becomes 7000)
        erc4626Vault.simulateYield(2000e18);

        // Verify totalBalanceOf proportions
        for (uint256 i = 0; i < users.length; i++) {
            uint256 expectedTotal = (deposits[i] * 7000e18) / 5000e18;
            assertApproxEqAbs(strategy.totalBalanceOf(address(underlyingToken), users[i]), expectedTotal, 1);
        }
    }

    // ============ WRONG TOKEN FOR VIEW FUNCTIONS ============

    function testPrincipalOfWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);
        vm.expectRevert("ERC4626YieldStrategy: only underlying token supported");
        strategy.principalOf(address(wrongToken), user1);
    }

    function testTotalBalanceOfWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);
        vm.expectRevert("ERC4626YieldStrategy: only underlying token supported");
        strategy.totalBalanceOf(address(wrongToken), user1);
    }

    // ============ skimSurplusBatch TESTS ============

    event SurplusSkimmed(
        address indexed token, address indexed client, address indexed withdrawer, uint256 amount, address recipient
    );

    /// @notice Batch skim over multiple clients performs EXACTLY ONE redeem
    function testSkimSurplusBatchSingleRedeem() public {
        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        strategy.deposit(address(underlyingToken), 2000e18, user2);
        strategy.deposit(address(underlyingToken), 3000e18, user3);
        vm.stopPrank();

        // 10% yield on 6000 total => 600 surplus
        erc4626Vault.simulateYield(600e18);

        address[] memory clients = new address[](3);
        clients[0] = user1;
        clients[1] = user2;
        clients[2] = user3;

        uint256 redeemsBefore = erc4626Vault.redeemCount();

        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);

        // Exactly one redeem for the whole batch
        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 1, "batch must do exactly one redeem");
    }

    /// @notice Recipient receives approximately the sum of snapshot surpluses (protocol-favoring dust)
    function testSkimSurplusBatchRecipientGetsSumOfSurplus() public {
        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        strategy.deposit(address(underlyingToken), 3000e18, user2);
        vm.stopPrank();

        // 25% yield on 4000 => 1000 surplus total
        erc4626Vault.simulateYield(1000e18);

        uint256 surplus1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        uint256 surplus2 = strategy.totalBalanceOf(address(underlyingToken), user2)
            - strategy.principalOf(address(underlyingToken), user2);
        uint256 expectedSum = surplus1 + surplus2;

        address[] memory clients = new address[](2);
        clients[0] = user1;
        clients[1] = user2;

        uint256 recipientBefore = underlyingToken.balanceOf(withdrawer);

        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);

        uint256 received = underlyingToken.balanceOf(withdrawer) - recipientBefore;

        // Received <= expected (protocol-favoring rounding), within small dust tolerance
        assertLe(received, expectedSum, "should not exceed snapshot surplus sum");
        assertApproxEqAbs(received, expectedSum, 5, "received approx sum of snapshot surplus");
    }

    /// @notice Batch skim leaves principal / getTotalDeposited unchanged
    function testSkimSurplusBatchPrincipalUnchanged() public {
        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        strategy.deposit(address(underlyingToken), 2000e18, user2);
        vm.stopPrank();

        erc4626Vault.simulateYield(300e18);

        uint256 totalDepositedBefore = strategy.getTotalDeposited(address(underlyingToken));

        address[] memory clients = new address[](2);
        clients[0] = user1;
        clients[1] = user2;

        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
        assertEq(strategy.principalOf(address(underlyingToken), user2), 2000e18);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), totalDepositedBefore);
    }

    /// @notice One SurplusSkimmed event per surplus-bearing client
    function testSkimSurplusBatchEmitsPerSurplusClient() public {
        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        strategy.deposit(address(underlyingToken), 1000e18, user2);
        vm.stopPrank();

        erc4626Vault.simulateYield(200e18);

        uint256 surplus1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        uint256 surplus2 = strategy.totalBalanceOf(address(underlyingToken), user2)
            - strategy.principalOf(address(underlyingToken), user2);

        address[] memory clients = new address[](2);
        clients[0] = user1;
        clients[1] = user2;

        // Expect one event per client, in iteration order
        vm.expectEmit(true, true, true, true);
        emit SurplusSkimmed(address(underlyingToken), user1, withdrawer, surplus1, withdrawer);
        vm.expectEmit(true, true, true, true);
        emit SurplusSkimmed(address(underlyingToken), user2, withdrawer, surplus2, withdrawer);

        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);
    }

    /// @notice Zero-surplus clients are skipped (no event, still one redeem for the rest)
    function testSkimSurplusBatchSkipsZeroSurplusClient() public {
        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        vm.stopPrank();

        erc4626Vault.simulateYield(100e18);

        // user2 and user3 have no deposit => zero principal => skipped
        address[] memory clients = new address[](3);
        clients[0] = user1;
        clients[1] = user2; // zero principal
        clients[2] = user3; // zero principal

        uint256 redeemsBefore = erc4626Vault.redeemCount();

        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);

        // Still exactly one redeem (only user1 had surplus)
        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 1, "one redeem despite zero-surplus clients");
        // user1 principal unchanged
        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
    }

    /// @notice No-op (no redeem) when there is no surplus at all
    function testSkimSurplusBatchNoSurplusNoRedeem() public {
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);

        address[] memory clients = new address[](1);
        clients[0] = user1;

        uint256 redeemsBefore = erc4626Vault.redeemCount();

        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);

        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 0, "no redeem when no surplus");
    }

    /// @notice Batch result matches the SNAPSHOT sum, not back-to-back sequential skims
    /// @dev Sequential skims are path-dependent (each re-reads totalValue after the prior redeem),
    ///      so the batch (single snapshot) extracts strictly more than two sequential full-surplus skims would.
    function testSkimSurplusBatchUsesSnapshotNotSequential() public {
        // Snapshot-path strategy
        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        strategy.deposit(address(underlyingToken), 1000e18, user2);
        vm.stopPrank();
        erc4626Vault.simulateYield(200e18);

        uint256 snapSurplus1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        uint256 snapSurplus2 = strategy.totalBalanceOf(address(underlyingToken), user2)
            - strategy.principalOf(address(underlyingToken), user2);
        uint256 snapshotSum = snapSurplus1 + snapSurplus2;

        address[] memory clients = new address[](2);
        clients[0] = user1;
        clients[1] = user2;

        uint256 beforeBal = underlyingToken.balanceOf(withdrawer);
        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);
        uint256 batchReceived = underlyingToken.balanceOf(withdrawer) - beforeBal;

        // Deploy a fresh identical strategy and run two SEQUENTIAL full-surplus skims
        MockERC4626Vault vault2 = new MockERC4626Vault("V2", "V2", address(underlyingToken));
        vm.prank(owner);
        ERC4626YieldStrategy strat2 = new ERC4626YieldStrategy(owner, address(underlyingToken), address(vault2));
        vm.startPrank(owner);
        strat2.setClient(client, true);
        strat2.setWithdrawer(withdrawer, true);
        vm.stopPrank();
        vm.prank(client);
        underlyingToken.approve(address(strat2), type(uint256).max);
        vm.startPrank(client);
        strat2.deposit(address(underlyingToken), 1000e18, user1);
        strat2.deposit(address(underlyingToken), 1000e18, user2);
        vm.stopPrank();
        vault2.simulateYield(200e18);

        uint256 before2 = underlyingToken.balanceOf(withdrawer);
        // First sequential skim of user1's full surplus
        uint256 seqSurplus1 = strat2.totalBalanceOf(address(underlyingToken), user1)
            - strat2.principalOf(address(underlyingToken), user1);
        vm.prank(withdrawer);
        strat2.skimSurplus(address(underlyingToken), user1, seqSurplus1, withdrawer);
        // Second sequential skim re-reads surplus for user2 AFTER the first redeem (path-dependent)
        uint256 seqSurplus2 = strat2.totalBalanceOf(address(underlyingToken), user2)
            - strat2.principalOf(address(underlyingToken), user2);
        vm.prank(withdrawer);
        strat2.skimSurplus(address(underlyingToken), user2, seqSurplus2, withdrawer);
        uint256 sequentialReceived = underlyingToken.balanceOf(withdrawer) - before2;

        // Batch == snapshot sum; sequential is strictly less (path-dependent shrinkage on second read)
        assertApproxEqAbs(batchReceived, snapshotSum, 5, "batch == snapshot sum");
        assertLt(sequentialReceived, batchReceived, "sequential extracts less than snapshot batch");
    }

    // ---- guard / access cases ----

    function testSkimSurplusBatchRevertsForNonWithdrawer() public {
        address[] memory clients = new address[](1);
        clients[0] = user1;
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized withdrawers");
        vm.prank(randomUser);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);
    }

    function testSkimSurplusBatchRevertsWhenPaused() public {
        address[] memory clients = new address[](1);
        clients[0] = user1;
        vm.prank(pauser);
        strategy.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);
    }

    function testSkimSurplusBatchRevertsZeroToken() public {
        address[] memory clients = new address[](1);
        clients[0] = user1;
        vm.expectRevert("AYieldStrategy: token cannot be zero address");
        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(0), clients, withdrawer);
    }

    function testSkimSurplusBatchRevertsZeroRecipient() public {
        address[] memory clients = new address[](1);
        clients[0] = user1;
        vm.expectRevert("AYieldStrategy: recipient cannot be zero address");
        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, address(0));
    }

    function testSkimSurplusBatchRevertsEmptyClients() public {
        address[] memory clients = new address[](0);
        vm.expectRevert("AYieldStrategy: empty clients");
        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);
    }

    function testSkimSurplusBatchRevertsZeroAddressClientEntry() public {
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        erc4626Vault.simulateYield(100e18);

        address[] memory clients = new address[](2);
        clients[0] = user1;
        clients[1] = address(0);

        vm.expectRevert("ERC4626YieldStrategy: client cannot be zero address");
        vm.prank(withdrawer);
        strategy.skimSurplusBatch(address(underlyingToken), clients, withdrawer);
    }
}
