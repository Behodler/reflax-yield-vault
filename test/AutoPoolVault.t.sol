// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/AutoPoolYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "./mocks/MockAutoPool.sol";
import "../src/mocks/MockMainRewarder.sol";

contract AutoPoolVaultTest is Test {
    AutoPoolYieldStrategy vault;
    MockERC20 underlyingToken;
    MockERC20 tokeToken;
    MockAutoPool autoPoolVault;
    MockMainRewarder mainRewarder;

    address owner = address(0x1234);
    address client1 = address(0x5678);
    address client2 = address(0x9ABC);
    address user1 = address(0xDEF0);
    address user2 = address(0x1357);

    uint256 constant INITIAL_TOKEN_SUPPLY = 10000000e18; // 10M tokens
    uint256 constant INITIAL_TOKE_SUPPLY = 1000000e18; // 1M TOKE

    function setUp() public {
        // Deploy mock tokens
        underlyingToken = new MockERC20("Underlying", "UNDERLYING", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock MainRewarder first
        mainRewarder = new MockMainRewarder(address(tokeToken));

        // Deploy mock autoPool vault
        autoPoolVault = new MockAutoPool("AutoPool", "autoPool", address(underlyingToken), address(mainRewarder));

        // Deploy the actual vault
        vm.prank(owner);
        vault = new AutoPoolYieldStrategy(
            owner, address(underlyingToken), address(tokeToken), address(autoPoolVault), address(mainRewarder)
        );

        // Mint tokens to test addresses
        underlyingToken.mint(client1, INITIAL_TOKEN_SUPPLY);
        underlyingToken.mint(client2, INITIAL_TOKEN_SUPPLY);
        underlyingToken.mint(address(autoPoolVault), INITIAL_TOKEN_SUPPLY); // For autoPool mock

        tokeToken.mint(address(mainRewarder), INITIAL_TOKE_SUPPLY);

        // Authorize clients
        vm.startPrank(owner);
        vault.setClient(client1, true);
        vault.setClient(client2, true);
        vm.stopPrank();
    }

    function testConstructor() public {
        // Test constructor requirements
        vm.expectRevert("AutoPoolYieldStrategy: underlying token cannot be zero address");
        new AutoPoolYieldStrategy(owner, address(0), address(tokeToken), address(autoPoolVault), address(mainRewarder));

        vm.expectRevert("AutoPoolYieldStrategy: TOKE token cannot be zero address");
        new AutoPoolYieldStrategy(
            owner, address(underlyingToken), address(0), address(autoPoolVault), address(mainRewarder)
        );

        vm.expectRevert("AutoPoolYieldStrategy: autopool vault cannot be zero address");
        new AutoPoolYieldStrategy(
            owner, address(underlyingToken), address(tokeToken), address(0), address(mainRewarder)
        );

        vm.expectRevert("AutoPoolYieldStrategy: MainRewarder cannot be zero address");
        new AutoPoolYieldStrategy(
            owner, address(underlyingToken), address(tokeToken), address(autoPoolVault), address(0)
        );

        // Test successful construction
        assertTrue(address(vault.underlyingToken()) == address(underlyingToken));
        assertTrue(address(vault.tokeToken()) == address(tokeToken));
        assertTrue(address(vault.autoPoolVault()) == address(autoPoolVault));
        assertTrue(address(vault.mainRewarder()) == address(mainRewarder));
    }

    function testDeposit() public {
        uint256 depositAmount = 1000e18; // 1000 tokens

        // Approve vault to spend tokens
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);

        // Get initial balances
        uint256 initialClientBalance = underlyingToken.balanceOf(client1);
        uint256 initialVaultShares = autoPoolVault.balanceOf(address(vault));
        uint256 initialStakedShares = mainRewarder.balanceOf(address(vault));

        // Perform deposit
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Verify tokens transferred from client
        assertEq(underlyingToken.balanceOf(client1), initialClientBalance - depositAmount);

        // Verify autoPool shares received and staked
        uint256 finalVaultShares = autoPoolVault.balanceOf(address(vault));
        uint256 finalStakedShares = mainRewarder.balanceOf(address(vault));

        assertTrue(finalVaultShares > initialVaultShares);
        assertTrue(finalStakedShares > initialStakedShares);

        // Verify user balance is tracked
        assertEq(vault.balanceOf(address(underlyingToken), user1), depositAmount);

        // Verify total deposited is updated
        assertEq(vault.getTotalDeposited(address(underlyingToken)), depositAmount);
    }

    function testDepositRequirements() public {
        uint256 depositAmount = 1000e18;

        // Test unauthorized client
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(address(0x9999));
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Test wrong token
        vm.expectRevert("AutoPoolYieldStrategy: only underlying token supported");
        vm.prank(client1);
        vault.deposit(address(tokeToken), depositAmount, user1);

        // Test zero amount
        vm.expectRevert("AutoPoolYieldStrategy: amount must be greater than zero");
        vm.prank(client1);
        vault.deposit(address(underlyingToken), 0, user1);

        // Test zero recipient
        vm.expectRevert("AutoPoolYieldStrategy: recipient cannot be zero address");
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, address(0));
    }

    function testWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;

        // First deposit - client1 deposits for client1 (themselves)
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, client1);

        // Get initial balances
        uint256 initialUserBalance = vault.balanceOf(address(underlyingToken), client1);
        uint256 initialRecipientBalance = underlyingToken.balanceOf(client1);

        // Perform withdrawal - client1 withdraws their own balance to themselves
        vm.prank(client1);
        vault.withdraw(address(underlyingToken), withdrawAmount, client1);

        // Verify balances
        uint256 finalUserBalance = vault.balanceOf(address(underlyingToken), client1);
        uint256 finalRecipientBalance = underlyingToken.balanceOf(client1);

        assertEq(finalUserBalance, initialUserBalance - withdrawAmount);
        assertEq(finalRecipientBalance, initialRecipientBalance + withdrawAmount);
    }

    function testWithdrawRequirements() public {
        uint256 withdrawAmount = 1000e18;

        // Test unauthorized client
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(address(0x9999));
        vault.withdraw(address(underlyingToken), withdrawAmount, user1);

        // Test wrong token
        vm.expectRevert("AutoPoolYieldStrategy: only underlying token supported");
        vm.prank(client1);
        vault.withdraw(address(tokeToken), withdrawAmount, user1);

        // Test zero amount
        vm.expectRevert("AutoPoolYieldStrategy: amount must be greater than zero");
        vm.prank(client1);
        vault.withdraw(address(underlyingToken), 0, user1);

        // Test zero recipient
        vm.expectRevert("AutoPoolYieldStrategy: recipient cannot be zero address");
        vm.prank(client1);
        vault.withdraw(address(underlyingToken), withdrawAmount, address(0));

        // Test insufficient balance
        vm.expectRevert("AutoPoolYieldStrategy: no shares available");
        vm.prank(client1);
        vault.withdraw(address(underlyingToken), withdrawAmount, user1);
    }

    function testTokeRewardsClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 rewardAmount = 50e18;

        // Deposit to enable staking
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Verify rewards are available
        assertEq(vault.getTokeRewards(), rewardAmount);

        // Only owner can claim
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", client1));
        vm.prank(client1);
        vault.claimTokeRewards(user1);

        // Owner claims rewards
        uint256 initialTokeBalance = tokeToken.balanceOf(user1);
        vm.prank(owner);
        vault.claimTokeRewards(user1);

        // Verify rewards transferred
        assertEq(tokeToken.balanceOf(user1), initialTokeBalance + rewardAmount);
        assertEq(vault.getTokeRewards(), 0);
    }

    function testEmergencyWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 emergencyAmount = 500e18;

        // Deposit first
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Only owner can emergency withdraw
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", client1));
        vm.prank(client1);
        vault.emergencyWithdraw(emergencyAmount);

        // Owner performs emergency withdraw
        uint256 initialOwnerBalance = underlyingToken.balanceOf(owner);
        vm.prank(owner);
        vault.emergencyWithdraw(emergencyAmount);

        // Verify withdrawal with precise assertion
        uint256 finalOwnerBalance = underlyingToken.balanceOf(owner);
        assertApproxEqAbs(
            finalOwnerBalance,
            initialOwnerBalance + emergencyAmount,
            1,
            "Emergency withdrawal should transfer requested amount within 1 wei"
        );
    }

    function testEmergencyWithdrawWhenStakedLessThanNeeded() public {
        uint256 depositAmount = 3000e18;

        // Setup: Make a deposit (this stakes the shares)
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Verify shares are staked
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertGt(stakedShares, 0, "Shares should be staked after deposit");

        // Manually unstake SOME shares to create the condition where staked < needed
        uint256 sharesToUnstake = stakedShares / 2; // Unstake half
        vm.prank(address(vault));
        mainRewarder.withdraw(address(vault), sharesToUnstake, false);

        // Now try to emergency withdraw a large amount that would need ALL shares
        uint256 largeWithdrawAmount = depositAmount;

        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);
        vm.prank(owner);
        vault.emergencyWithdraw(largeWithdrawAmount);

        // Should succeed and withdraw what's possible
        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        assertGt(
            ownerBalanceAfter, ownerBalanceBefore, "Should withdraw some amount even with insufficient staked shares"
        );
    }

    function testEmergencyWithdrawZeroStaked() public {
        uint256 depositAmount = 1500e18;

        // Setup: Make a deposit
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Manually unstake ALL shares to create zero-staked condition
        uint256 allStakedShares = mainRewarder.balanceOf(address(vault));
        vm.prank(address(vault));
        mainRewarder.withdraw(address(vault), allStakedShares, false);

        // Verify zero staked
        assertEq(mainRewarder.balanceOf(address(vault)), 0, "Should have zero staked shares");

        // But vault still has shares (just not staked)
        assertGt(autoPoolVault.balanceOf(address(vault)), 0, "Vault should still have autoPool shares");

        // Emergency withdraw requires staked shares > 0
        uint256 withdrawAmount = 500e18;

        vm.prank(owner);
        vm.expectRevert("AutoPoolYieldStrategy: no shares to withdraw");
        vault.emergencyWithdraw(withdrawAmount);
    }

    function testZeroBalanceQueries() public {
        // Test balance queries for non-existent deposits
        assertEq(vault.balanceOf(address(underlyingToken), user1), 0);
        assertEq(vault.getTotalDeposited(address(underlyingToken)), 0);
        assertEq(vault.getTotalShares(), 0);
        assertEq(vault.getTokeRewards(), 0);
    }

    function testOnlyUnderlyingTokenSupported() public {
        // Create another ERC20 token
        MockERC20 otherToken = new MockERC20("OTHER", "OTHER", 18);

        // Verify balance query rejects non-underlying tokens
        vm.expectRevert("AutoPoolYieldStrategy: only underlying token supported");
        vault.balanceOf(address(otherToken), user1);
    }

    function testWithdrawWithClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;
        uint256 rewardAmount = 50e18;

        // First deposit
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, client1);

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Verify rewards are available
        assertEq(vault.getTokeRewards(), rewardAmount);

        // Perform withdrawal
        vm.prank(client1);
        vault.withdraw(address(underlyingToken), withdrawAmount, client1);

        // Test the mock directly
        uint256 stakeAmount = 100e18;
        mainRewarder.stake(user1, stakeAmount);
        mainRewarder.simulateRewards(user1, rewardAmount);

        uint256 userTokeBalanceBefore = tokeToken.balanceOf(user1);
        mainRewarder.withdraw(user1, stakeAmount, true);
        uint256 userTokeBalanceAfter = tokeToken.balanceOf(user1);

        // Verify rewards were claimed during withdrawal
        assertEq(userTokeBalanceAfter, userTokeBalanceBefore + rewardAmount);
        assertEq(mainRewarder.earned(user1), 0);
    }

    function testGetRewardWithRecipient() public {
        uint256 depositAmount = 1000e18;
        uint256 rewardAmount = 50e18;

        // Deposit to enable staking
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Simulate earning TOKE rewards for the vault
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Test the mock directly to verify recipient parameter works
        mainRewarder.simulateRewards(user1, rewardAmount);

        uint256 user2TokeBalanceBefore = tokeToken.balanceOf(user2);
        mainRewarder.getReward(user1, user2, false);
        uint256 user2TokeBalanceAfter = tokeToken.balanceOf(user2);

        // Verify rewards were sent to user2 (not user1)
        assertEq(user2TokeBalanceAfter, user2TokeBalanceBefore + rewardAmount);
        assertEq(mainRewarder.earned(user1), 0);
        assertEq(tokeToken.balanceOf(user1), 0);
    }

    // ============ _totalWithdraw Unit Tests ============

    function testTotalWithdrawCalculatesCorrectShares() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 3000e18;

        // Client 1 deposits for user1
        vm.prank(client1);
        underlyingToken.approve(address(vault), deposit1);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), deposit1, user1);

        // Client 2 deposits for user2
        vm.prank(client2);
        underlyingToken.approve(address(vault), deposit2);
        vm.prank(client2);
        vault.deposit(address(underlyingToken), deposit2, user2);

        // Get total shares
        uint256 totalSharesBefore = autoPoolVault.balanceOf(address(vault));
        uint256 expectedSharesForUser1 = (totalSharesBefore * deposit1) / (deposit1 + deposit2);

        // Initiate total withdrawal for user1
        vm.prank(owner);
        vault.totalWithdrawal(address(underlyingToken), user1);

        // Advance time past waiting period
        vm.warp(block.timestamp + 24 hours + 1);

        // Get owner's initial balance
        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);

        // Execute total withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(underlyingToken), user1);

        // Verify correct amount of shares were withdrawn
        uint256 totalSharesAfter = autoPoolVault.balanceOf(address(vault));
        uint256 sharesWithdrawn = totalSharesBefore - totalSharesAfter;

        // Allow for small rounding errors
        uint256 tolerance = expectedSharesForUser1 / 1000;
        assertTrue(
            sharesWithdrawn >= expectedSharesForUser1 - tolerance
                && sharesWithdrawn <= expectedSharesForUser1 + tolerance,
            "Share calculation should be accurate"
        );

        // Verify owner received approximately the right amount
        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        uint256 received = ownerBalanceAfter - ownerBalanceBefore;
        assertTrue(received >= deposit1 - tolerance && received <= deposit1 + tolerance);
    }

    function testTotalWithdrawBalanceReset() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;

        // Client 1 deposits for user1
        vm.prank(client1);
        underlyingToken.approve(address(vault), deposit1);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), deposit1, user1);

        // Client 2 deposits for user2
        vm.prank(client2);
        underlyingToken.approve(address(vault), deposit2);
        vm.prank(client2);
        vault.deposit(address(underlyingToken), deposit2, user2);

        // Verify initial balances
        assertEq(vault.balanceOf(address(underlyingToken), user1), deposit1);
        assertEq(vault.getTotalDeposited(address(underlyingToken)), deposit1 + deposit2);

        // Initiate total withdrawal for user1
        vm.prank(owner);
        vault.totalWithdrawal(address(underlyingToken), user1);

        // Advance time past waiting period
        vm.warp(block.timestamp + 24 hours + 1);

        // Execute total withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(underlyingToken), user1);

        // Verify user1 balance is reset to zero
        assertEq(vault.balanceOf(address(underlyingToken), user1), 0, "Client balance should be reset to zero");

        // Verify totalDeposited is updated correctly
        assertEq(vault.getTotalDeposited(address(underlyingToken)), deposit2, "Total deposited should be reduced");

        // Verify user2 balance is unaffected
        assertEq(vault.balanceOf(address(underlyingToken), user2), deposit2, "Other client balance should be unchanged");
    }

    function testTotalWithdrawZeroShares() public {
        // Try to withdraw from a client with no balance
        vm.expectRevert("AYieldStrategy: no balance to withdraw");
        vm.prank(owner);
        vault.totalWithdrawal(address(underlyingToken), user1);

        // Verify vault state is unchanged
        assertEq(vault.getTotalShares(), 0, "Total shares should remain zero");
        assertEq(vault.getTotalDeposited(address(underlyingToken)), 0, "Total deposited should remain zero");
    }

    // ============ balanceOf() Edge Case Tests ============

    function testBalanceOfPrecisionWithSmallValues() public {
        // Test with 1 wei
        vm.prank(client1);
        underlyingToken.approve(address(vault), 1);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), 1, user1);

        uint256 balance1Wei = vault.balanceOf(address(underlyingToken), user1);
        assertGe(balance1Wei, 1, "Balance should be at least 1 wei");

        // Test with 100 wei
        vm.prank(client1);
        underlyingToken.approve(address(vault), 100);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), 100, user1);

        uint256 balance101Wei = vault.balanceOf(address(underlyingToken), user1);
        assertGe(balance101Wei, 101, "Balance should be at least 101 wei");
    }

    function testBalanceOfPrecisionWithLargeValues() public {
        // Mint large amounts for testing
        uint256 largeAmount = 1e30;
        underlyingToken.mint(client1, largeAmount);
        underlyingToken.mint(address(autoPoolVault), largeAmount);

        // Deposit large amount
        vm.prank(client1);
        underlyingToken.approve(address(vault), largeAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), largeAmount, user1);

        uint256 balanceLarge = vault.balanceOf(address(underlyingToken), user1);
        assertGe(balanceLarge, largeAmount, "Balance should be at least the deposit amount");

        // Allow for minimal rounding
        uint256 maxTolerance = largeAmount / 10000;
        assertLe(balanceLarge, largeAmount + maxTolerance, "Balance should not significantly exceed deposit");
    }

    // ============ Rounding Error Tests ============

    function testDepositWithdrawOneWei() public {
        uint256 oneWei = 1;

        // Approve and deposit exactly 1 wei
        vm.prank(client1);
        underlyingToken.approve(address(vault), oneWei);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), oneWei, client1);

        // Verify shares were received
        uint256 sharesReceived = autoPoolVault.balanceOf(address(vault));
        assertGe(sharesReceived, 1, "Should receive at least 1 share for 1 wei deposit");

        // Verify client1 balance is tracked correctly
        uint256 clientBalance = vault.balanceOf(address(underlyingToken), client1);
        assertApproxEqAbs(
            clientBalance, oneWei, 1, "Client balance should be approximately 1 wei within 1 wei tolerance"
        );

        // Withdraw the 1 wei
        uint256 recipientBalanceBefore = underlyingToken.balanceOf(client1);
        vm.prank(client1);
        vault.withdraw(address(underlyingToken), oneWei, client1);

        // Verify withdrawal succeeded
        uint256 recipientBalanceAfter = underlyingToken.balanceOf(client1);
        uint256 amountReceived = recipientBalanceAfter - recipientBalanceBefore;

        // With 1 wei operations, we allow 1 wei tolerance for rounding
        assertApproxEqAbs(amountReceived, oneWei, 1, "Should receive approximately 1 wei within rounding tolerance");
    }

    function testMultipleSmallDepositsAccounting() public {
        uint256 dustAmount = 10; // 10 wei per deposit
        uint256 numDeposits = 100;
        uint256 totalExpected = dustAmount * numDeposits;

        // Perform multiple small deposits
        vm.startPrank(client1);
        underlyingToken.approve(address(vault), totalExpected);

        for (uint256 i = 0; i < numDeposits; i++) {
            vault.deposit(address(underlyingToken), dustAmount, client1);
        }
        vm.stopPrank();

        // Verify total shares were accumulated
        uint256 totalShares = autoPoolVault.balanceOf(address(vault));
        assertGt(totalShares, 0, "Should have accumulated shares from dust deposits");

        // Verify client1 balance matches expected total within rounding tolerance
        uint256 clientBalance = vault.balanceOf(address(underlyingToken), client1);

        // Allow for accumulated rounding errors
        uint256 tolerance = numDeposits;
        assertApproxEqAbs(
            clientBalance,
            totalExpected,
            tolerance,
            "Total balance should match sum of deposits within rounding tolerance"
        );
    }

    // ============ TOKE Reward Interference Tests ============

    function testClaimRewardsDuringPendingTotalWithdrawal() public {
        uint256 depositAmount = 5000e18;
        uint256 rewardAmount = 100e18;

        // Setup: Make a deposit
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Verify rewards are available before total withdrawal
        uint256 rewardsBeforeWithdrawal = vault.getTokeRewards();
        assertEq(rewardsBeforeWithdrawal, rewardAmount, "Rewards should be available before total withdrawal");

        // Initiate total withdrawal (starts 24-hour waiting period)
        vm.prank(owner);
        vault.totalWithdrawal(address(underlyingToken), user1);

        // Record user balance before claiming rewards
        uint256 userBalanceBeforeClaim = vault.balanceOf(address(underlyingToken), user1);
        uint256 totalDepositedBeforeClaim = vault.getTotalDeposited(address(underlyingToken));
        uint256 totalSharesBeforeClaim = vault.getTotalShares();

        // While total withdrawal is pending, claim TOKE rewards
        uint256 ownerTokeBalanceBefore = tokeToken.balanceOf(owner);
        vm.prank(owner);
        vault.claimTokeRewards(owner);

        // Verify rewards were claimed successfully
        uint256 ownerTokeBalanceAfter = tokeToken.balanceOf(owner);
        assertEq(ownerTokeBalanceAfter, ownerTokeBalanceBefore + rewardAmount, "Owner should receive TOKE rewards");
        assertEq(vault.getTokeRewards(), 0, "Rewards should be fully claimed");

        // CRITICAL: Verify that claiming rewards didn't corrupt withdrawal state
        uint256 userBalanceAfterClaim = vault.balanceOf(address(underlyingToken), user1);
        uint256 totalDepositedAfterClaim = vault.getTotalDeposited(address(underlyingToken));
        uint256 totalSharesAfterClaim = vault.getTotalShares();

        assertEq(
            userBalanceAfterClaim, userBalanceBeforeClaim, "User balance should not change when rewards are claimed"
        );
        assertEq(
            totalDepositedAfterClaim,
            totalDepositedBeforeClaim,
            "Total deposited should not change when rewards are claimed"
        );
        assertEq(
            totalSharesAfterClaim, totalSharesBeforeClaim, "Total shares should not change when rewards are claimed"
        );

        // Fast forward to complete total withdrawal window
        vm.warp(block.timestamp + 24 hours + 1 seconds);

        // Complete the total withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(underlyingToken), user1);

        // Verify total withdrawal completed successfully
        assertEq(
            vault.balanceOf(address(underlyingToken), user1),
            0,
            "Total withdrawal should complete and zero user balance"
        );
    }

    function testClaimRewardsNoStake() public {
        // Verify vault starts with no staked shares
        uint256 initialStakedShares = mainRewarder.balanceOf(address(vault));
        assertEq(initialStakedShares, 0, "Vault should have no staked shares initially");

        // Verify no rewards are available
        uint256 initialRewards = vault.getTokeRewards();
        assertEq(initialRewards, 0, "No rewards should be available with no stake");

        // Attempt to claim rewards with zero stake
        uint256 ownerTokeBalanceBefore = tokeToken.balanceOf(owner);

        vm.prank(owner);
        vault.claimTokeRewards(owner);

        // Verify claim succeeded but transferred zero tokens
        uint256 ownerTokeBalanceAfter = tokeToken.balanceOf(owner);
        assertEq(ownerTokeBalanceAfter, ownerTokeBalanceBefore, "Owner should receive zero TOKE with no stake");
    }

    function testTokeRewardsClaimImproved() public {
        uint256 depositAmount = 1000e18;
        uint256 rewardAmount = 50e18;

        // Deposit to enable staking
        vm.prank(client1);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Verify shares are staked
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertGt(stakedShares, 0, "Shares should be staked after deposit");

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // INTERMEDIATE ASSERTION: Verify exact reward amount is available before claiming
        uint256 rewardsAvailableBeforeClaim = vault.getTokeRewards();
        assertEq(rewardsAvailableBeforeClaim, rewardAmount, "Exact reward amount should be available before claim");

        // Record vault's TOKE balance before claim (should be zero initially)
        uint256 vaultTokeBalanceBeforeClaim = tokeToken.balanceOf(address(vault));
        assertEq(vaultTokeBalanceBeforeClaim, 0, "Vault should have no TOKE tokens before claim");

        // Only owner can claim (verify authorization)
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", client1));
        vm.prank(client1);
        vault.claimTokeRewards(user1);

        // Owner claims rewards
        uint256 recipientTokeBalanceBefore = tokeToken.balanceOf(user1);

        vm.prank(owner);
        vault.claimTokeRewards(user1);

        // INTERMEDIATE ASSERTION: Verify exact reward amount was transferred to recipient
        uint256 recipientTokeBalanceAfter = tokeToken.balanceOf(user1);
        uint256 actualRewardsReceived = recipientTokeBalanceAfter - recipientTokeBalanceBefore;
        assertEq(actualRewardsReceived, rewardAmount, "Recipient should receive exact reward amount");

        // Verify rewards are now zero after claiming
        uint256 rewardsAfterClaim = vault.getTokeRewards();
        assertEq(rewardsAfterClaim, 0, "Rewards should be zero after claiming");
    }
}
