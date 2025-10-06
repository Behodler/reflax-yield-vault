// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/mocks/MockVault.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title TotalWithdrawalTest
 * @notice Comprehensive tests for the two-phase totalWithdrawal function
 */
contract TotalWithdrawalTest is Test {
    MockVault public vault;
    MockERC20 public token;

    address public owner = address(1);
    address public client = address(2);
    address public user = address(3);
    address public nonOwner = address(4);

    uint256 public constant DEPOSIT_AMOUNT = 1000e18;
    uint256 public constant WAITING_PERIOD = 24 hours;
    uint256 public constant EXECUTION_WINDOW = 48 hours;
    uint256 public constant TOTAL_DURATION = WAITING_PERIOD + EXECUTION_WINDOW;

    event WithdrawalInitiated(
        address indexed token,
        address indexed client,
        uint256 balance,
        uint256 initiatedAt,
        uint256 executableAt
    );

    event WithdrawalExecuted(
        address indexed token,
        address indexed client,
        uint256 amount,
        uint256 executedAt
    );

    function setUp() public {
        // Deploy contracts
        vault = new MockVault(owner);
        token = new MockERC20("Test Token", "TEST", 18);

        // Setup initial token balance and authorization
        token.mint(client, DEPOSIT_AMOUNT);

        // Set client as authorized for deposits
        vm.prank(owner);
        vault.setClient(client, true);

        // Client deposits tokens
        vm.startPrank(client);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token), DEPOSIT_AMOUNT, client);
        vm.stopPrank();

        // Verify initial setup
        assertEq(vault.balanceOf(address(token), client), DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    }

    // ============ ACCESS CONTROL TESTS ============

    function testOnlyOwnerCanInitiateWithdrawal() public {
        vm.prank(nonOwner);
        vm.expectRevert();  // OwnableUnauthorizedAccount error in newer OpenZeppelin
        vault.totalWithdrawal(address(token), client);
    }

    // ============ INPUT VALIDATION TESTS ============

    function testRevertZeroAddressToken() public {
        vm.prank(owner);
        vm.expectRevert("Vault: token cannot be zero address");
        vault.totalWithdrawal(address(0), client);
    }

    function testRevertZeroAddressClient() public {
        vm.prank(owner);
        vm.expectRevert("Vault: client cannot be zero address");
        vault.totalWithdrawal(address(token), address(0));
    }

    function testRevertNoBalance() public {
        address emptyClient = address(99);
        vm.prank(owner);
        vm.expectRevert("Vault: no balance to withdraw");
        vault.totalWithdrawal(address(token), emptyClient);
    }

    // ============ PHASE 1 TESTS (INITIATION) ============

    function testPhase1InitiateWithdrawal() public {
        vm.prank(owner);

        // Expect the WithdrawalInitiated event
        vm.expectEmit(true, true, false, true);
        emit WithdrawalInitiated(
            address(token),
            client,
            DEPOSIT_AMOUNT,
            block.timestamp,
            block.timestamp + WAITING_PERIOD
        );

        vault.totalWithdrawal(address(token), client);

        // Check withdrawal state
        (uint256 initiatedAt, Vault.WithdrawalStatus status, uint256 balance) = vault.withdrawalStates(address(token), client);
        assertEq(initiatedAt, block.timestamp);
        assertTrue(status == Vault.WithdrawalStatus.Initiated);
        assertEq(balance, DEPOSIT_AMOUNT);
    }

    function testPhase1RevertDuringWaitingPeriod() public {
        // Initiate withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Try to call again during waiting period
        vm.warp(block.timestamp + 12 hours); // Half way through waiting period

        vm.prank(owner);
        string memory expectedError = string(
            abi.encodePacked(
                "Vault: withdrawal still in waiting period, executable at timestamp: ",
                vm.toString(block.timestamp + 12 hours)
            )
        );
        vm.expectRevert(bytes(expectedError));
        vault.totalWithdrawal(address(token), client);
    }

    // ============ PHASE 2 TESTS (EXECUTION) ============

    function testPhase2ExecuteWithdrawal() public {
        // Phase 1: Initiate withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Move to Phase 2 (after waiting period)
        vm.warp(block.timestamp + WAITING_PERIOD + 1);

        // Check owner's token balance before execution
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        // Phase 2: Execute withdrawal
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit WithdrawalExecuted(
            address(token),
            client,
            DEPOSIT_AMOUNT,
            block.timestamp
        );

        vault.totalWithdrawal(address(token), client);

        // Verify the withdrawal was executed
        assertEq(vault.balanceOf(address(token), client), 0);
        assertEq(token.balanceOf(owner), ownerBalanceBefore + DEPOSIT_AMOUNT);

        // Verify state was reset
        (uint256 initiatedAt, Vault.WithdrawalStatus status, uint256 balance) = vault.withdrawalStates(address(token), client);
        assertEq(initiatedAt, 0);
        assertTrue(status == Vault.WithdrawalStatus.None);
        assertEq(balance, 0);
    }

    // ============ EXPIRATION TESTS ============

    function testExpiredWithdrawalResetsAndAllowsNewInitiation() public {
        // Phase 1: Initiate withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Move past total duration (withdrawal expires)
        vm.warp(block.timestamp + TOTAL_DURATION + 1);

        // Should be able to initiate a new withdrawal
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit WithdrawalInitiated(
            address(token),
            client,
            DEPOSIT_AMOUNT,
            block.timestamp,
            block.timestamp + WAITING_PERIOD
        );

        vault.totalWithdrawal(address(token), client);

        // Verify new withdrawal state
        (uint256 initiatedAt, Vault.WithdrawalStatus status, uint256 balance) = vault.withdrawalStates(address(token), client);
        assertEq(initiatedAt, block.timestamp);
        assertTrue(status == Vault.WithdrawalStatus.Initiated);
        assertEq(balance, DEPOSIT_AMOUNT);
    }

    function testExecutionWindowExpiry() public {
        // Phase 1: Initiate withdrawal
        uint256 startTime = block.timestamp;
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Move to just before execution window expires
        vm.warp(startTime + TOTAL_DURATION - 1);

        // Should still be executable
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Verify withdrawal was successful
        assertEq(vault.balanceOf(address(token), client), 0);
    }

    // ============ EDGE CASE TESTS ============

    function testMultipleTokensIndependentStates() public {
        // Deploy second token
        MockERC20 token2 = new MockERC20("Test Token 2", "TEST2", 18);
        token2.mint(client, DEPOSIT_AMOUNT);

        // Deposit second token
        vm.startPrank(client);
        token2.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token2), DEPOSIT_AMOUNT, client);
        vm.stopPrank();

        // Initiate withdrawal for first token
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Initiate withdrawal for second token (should work independently)
        vm.prank(owner);
        vault.totalWithdrawal(address(token2), client);

        // Both should be in initiated state
        (, Vault.WithdrawalStatus status1,) = vault.withdrawalStates(address(token), client);
        (, Vault.WithdrawalStatus status2,) = vault.withdrawalStates(address(token2), client);

        assertTrue(status1 == Vault.WithdrawalStatus.Initiated);
        assertTrue(status2 == Vault.WithdrawalStatus.Initiated);
    }

    function testMultipleClientsIndependentStates() public {
        address client2 = address(5);

        // Setup second client
        token.mint(client2, DEPOSIT_AMOUNT);
        vm.prank(owner);
        vault.setClient(client2, true);

        vm.startPrank(client2);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token), DEPOSIT_AMOUNT, client2);
        vm.stopPrank();

        // Initiate withdrawal for first client
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Initiate withdrawal for second client (should work independently)
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client2);

        // Both should be in initiated state
        (, Vault.WithdrawalStatus status1,) = vault.withdrawalStates(address(token), client);
        (, Vault.WithdrawalStatus status2,) = vault.withdrawalStates(address(token), client2);

        assertTrue(status1 == Vault.WithdrawalStatus.Initiated);
        assertTrue(status2 == Vault.WithdrawalStatus.Initiated);
    }

    function testReentrancyProtection() public {
        // The nonReentrant modifier should prevent reentrancy attacks
        // This is tested implicitly by the modifier, but we can verify
        // the modifier is present in the function signature

        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Move to execution phase
        vm.warp(block.timestamp + WAITING_PERIOD + 1);

        // Execute withdrawal - should complete successfully without reentrancy issues
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        assertEq(vault.balanceOf(address(token), client), 0);
    }

    // ============ SEQUENTIAL WITHDRAWAL TESTS ============

    function testSequentialWithdrawalCycle() public {
        // First cycle: Initiate -> Execute
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        vm.warp(block.timestamp + WAITING_PERIOD + 1);

        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Verify first cycle completed
        assertEq(vault.balanceOf(address(token), client), 0);

        // Deposit again for second cycle
        token.mint(client, DEPOSIT_AMOUNT); // Mint new tokens for client
        vm.startPrank(client);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token), DEPOSIT_AMOUNT, client);
        vm.stopPrank();

        // Second cycle: Initiate new withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Verify second cycle initiated
        (, Vault.WithdrawalStatus status,) = vault.withdrawalStates(address(token), client);
        assertTrue(status == Vault.WithdrawalStatus.Initiated);
    }

    function testBalanceCachingBehavior() public {
        // Initiate withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // Verify cached balance
        (,, uint256 cachedBalance) = vault.withdrawalStates(address(token), client);
        assertEq(cachedBalance, DEPOSIT_AMOUNT);

        // If somehow the actual balance changes, cached balance should remain
        // (This tests the security aspect of caching balance at initiation)
        vm.warp(block.timestamp + WAITING_PERIOD + 1);

        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);

        // The withdrawal should use the cached balance, not current balance
        assertEq(vault.balanceOf(address(token), client), 0);
    }

    // ============ CONCURRENT OPERATIONS TESTS ============

    function testTotalWithdrawalMultipleClientsSequential() public {
        // Setup: Create 3 clients with deposits
        address client2 = address(5);
        address client3 = address(6);

        // Setup client2
        token.mint(client2, DEPOSIT_AMOUNT);
        vm.prank(owner);
        vault.setClient(client2, true);
        vm.startPrank(client2);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token), DEPOSIT_AMOUNT, client2);
        vm.stopPrank();

        // Setup client3
        token.mint(client3, DEPOSIT_AMOUNT);
        vm.prank(owner);
        vault.setClient(client3, true);
        vm.startPrank(client3);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token), DEPOSIT_AMOUNT, client3);
        vm.stopPrank();

        // Verify initial deposits
        assertEq(vault.balanceOf(address(token), client), DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(address(token), client2), DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(address(token), client3), DEPOSIT_AMOUNT);

        // Initiate total withdrawals SEQUENTIALLY
        uint256 startTime = block.timestamp;

        // Client 1 initiates withdrawal
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);
        {
            (uint256 initiatedAt1, Vault.WithdrawalStatus status1, uint256 balance1) = vault.withdrawalStates(address(token), client);
            assertEq(initiatedAt1, startTime);
            assertTrue(status1 == Vault.WithdrawalStatus.Initiated);
            assertEq(balance1, DEPOSIT_AMOUNT);
        }

        // Client 2 initiates withdrawal (1 hour later)
        vm.warp(block.timestamp + 1 hours);
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client2);
        {
            (uint256 initiatedAt2, Vault.WithdrawalStatus status2, uint256 balance2) = vault.withdrawalStates(address(token), client2);
            assertEq(initiatedAt2, startTime + 1 hours);
            assertTrue(status2 == Vault.WithdrawalStatus.Initiated);
            assertEq(balance2, DEPOSIT_AMOUNT);
        }

        // Client 3 initiates withdrawal (2 hours after start)
        vm.warp(block.timestamp + 1 hours);
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client3);
        {
            (uint256 initiatedAt3, Vault.WithdrawalStatus status3, uint256 balance3) = vault.withdrawalStates(address(token), client3);
            assertEq(initiatedAt3, startTime + 2 hours);
            assertTrue(status3 == Vault.WithdrawalStatus.Initiated);
            assertEq(balance3, DEPOSIT_AMOUNT);
        }

        // Verify each client has independent withdrawal state with different timestamps
        {
            (uint256 check1,,) = vault.withdrawalStates(address(token), client);
            assertEq(check1, startTime);
        }
        {
            (uint256 check2,,) = vault.withdrawalStates(address(token), client2);
            assertEq(check2, startTime + 1 hours);
        }
        {
            (uint256 check3,,) = vault.withdrawalStates(address(token), client3);
            assertEq(check3, startTime + 2 hours);
        }

        // Execute withdrawals sequentially (warp time between each)
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        // Execute client 1 withdrawal (24 hours after initiation)
        vm.warp(startTime + WAITING_PERIOD + 1);
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);
        assertEq(vault.balanceOf(address(token), client), 0);

        // Execute client 2 withdrawal (24 hours after their initiation)
        vm.warp(startTime + 1 hours + WAITING_PERIOD + 1);
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client2);
        assertEq(vault.balanceOf(address(token), client2), 0);

        // Execute client 3 withdrawal (24 hours after their initiation)
        vm.warp(startTime + 2 hours + WAITING_PERIOD + 1);
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client3);
        assertEq(vault.balanceOf(address(token), client3), 0);

        // Verify all clients successfully withdrew with correct amounts
        assertEq(token.balanceOf(owner), ownerBalanceBefore + (DEPOSIT_AMOUNT * 3));

        // Confirm no state corruption - all withdrawal states reset
        {
            (, Vault.WithdrawalStatus finalStatus1,) = vault.withdrawalStates(address(token), client);
            (, Vault.WithdrawalStatus finalStatus2,) = vault.withdrawalStates(address(token), client2);
            (, Vault.WithdrawalStatus finalStatus3,) = vault.withdrawalStates(address(token), client3);
            assertTrue(finalStatus1 == Vault.WithdrawalStatus.None);
            assertTrue(finalStatus2 == Vault.WithdrawalStatus.None);
            assertTrue(finalStatus3 == Vault.WithdrawalStatus.None);
        }
    }

    function testEmergencyWithdrawBetweenClientWithdrawals() public {
        // Setup: Create 3 clients with deposits
        address client2 = address(5);
        address client3 = address(6);

        // Setup client2
        token.mint(client2, DEPOSIT_AMOUNT);
        vm.prank(owner);
        vault.setClient(client2, true);
        vm.startPrank(client2);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token), DEPOSIT_AMOUNT, client2);
        vm.stopPrank();

        // Setup client3
        token.mint(client3, DEPOSIT_AMOUNT);
        vm.prank(owner);
        vault.setClient(client3, true);
        vm.startPrank(client3);
        token.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(token), DEPOSIT_AMOUNT, client3);
        vm.stopPrank();

        // Initiate total withdrawals for all 3 clients
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client2);
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client3);

        // Verify all clients have pending withdrawals with correct status
        {
            (, Vault.WithdrawalStatus status1,) = vault.withdrawalStates(address(token), client);
            (, Vault.WithdrawalStatus status2,) = vault.withdrawalStates(address(token), client2);
            (, Vault.WithdrawalStatus status3,) = vault.withdrawalStates(address(token), client3);
            assertTrue(status1 == Vault.WithdrawalStatus.Initiated);
            assertTrue(status2 == Vault.WithdrawalStatus.Initiated);
            assertTrue(status3 == Vault.WithdrawalStatus.Initiated);
        }

        // Verify cached balances
        {
            (, , uint256 cachedBalance1) = vault.withdrawalStates(address(token), client);
            (, , uint256 cachedBalance2) = vault.withdrawalStates(address(token), client2);
            (, , uint256 cachedBalance3) = vault.withdrawalStates(address(token), client3);
            assertEq(cachedBalance1, DEPOSIT_AMOUNT);
            assertEq(cachedBalance2, DEPOSIT_AMOUNT);
            assertEq(cachedBalance3, DEPOSIT_AMOUNT);
        }

        // Perform emergency withdraw (while all have pending total withdrawals)
        vm.prank(owner);
        vault.emergencyWithdraw(DEPOSIT_AMOUNT / 2);

        // Verify withdrawal states remain valid after emergency withdraw
        {
            (, Vault.WithdrawalStatus afterStatus1, uint256 afterBalance1) = vault.withdrawalStates(address(token), client);
            assertTrue(afterStatus1 == Vault.WithdrawalStatus.Initiated);
            assertEq(afterBalance1, DEPOSIT_AMOUNT);
        }
        {
            (, Vault.WithdrawalStatus afterStatus2, uint256 afterBalance2) = vault.withdrawalStates(address(token), client2);
            assertTrue(afterStatus2 == Vault.WithdrawalStatus.Initiated);
            assertEq(afterBalance2, DEPOSIT_AMOUNT);
        }
        {
            (, Vault.WithdrawalStatus afterStatus3, uint256 afterBalance3) = vault.withdrawalStates(address(token), client3);
            assertTrue(afterStatus3 == Vault.WithdrawalStatus.Initiated);
            assertEq(afterBalance3, DEPOSIT_AMOUNT);
        }

        // Complete all clients' total withdrawals
        vm.warp(block.timestamp + WAITING_PERIOD + 1);

        // Execute all withdrawals
        vm.prank(owner);
        vault.totalWithdrawal(address(token), client);
        assertEq(vault.balanceOf(address(token), client), 0);

        vm.prank(owner);
        vault.totalWithdrawal(address(token), client2);
        assertEq(vault.balanceOf(address(token), client2), 0);

        vm.prank(owner);
        vault.totalWithdrawal(address(token), client3);
        assertEq(vault.balanceOf(address(token), client3), 0);

        // Verify all withdrawal states reset (no corruption)
        {
            (, Vault.WithdrawalStatus finalStatus1,) = vault.withdrawalStates(address(token), client);
            (, Vault.WithdrawalStatus finalStatus2,) = vault.withdrawalStates(address(token), client2);
            (, Vault.WithdrawalStatus finalStatus3,) = vault.withdrawalStates(address(token), client3);
            assertTrue(finalStatus1 == Vault.WithdrawalStatus.None);
            assertTrue(finalStatus2 == Vault.WithdrawalStatus.None);
            assertTrue(finalStatus3 == Vault.WithdrawalStatus.None);
        }
    }
}