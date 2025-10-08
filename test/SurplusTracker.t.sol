// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/SurplusTracker.sol";
import "../src/mocks/MockVault.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title SurplusTrackerTest
 * @notice Comprehensive unit tests for SurplusTracker contract
 */
contract SurplusTrackerTest is Test {
    SurplusTracker public tracker;
    MockVault public vault;
    MockERC20 public token;

    address public owner;
    address public client;
    address public recipient;

    function setUp() public {
        owner = address(this);
        client = address(0x1);
        recipient = address(0x2);

        tracker = new SurplusTracker();
        vault = new MockVault(owner);
        token = new MockERC20("Test Token", "TEST", 18);

        // Authorize client for vault operations
        vault.setClient(client, true);

        // Mint tokens to client for testing
        token.mint(client, 10000e18);
    }

    // ============ BASIC FUNCTIONALITY TESTS ============

    function testGetSurplusWithPositiveSurplus() public {
        // Setup: Client has 1000 tokens in vault (actual balance)
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal accounting shows 900 (yield has accrued)
        uint256 clientInternalBalance = 900e18;

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            clientInternalBalance
        );

        // Surplus should be 1000 - 900 = 100
        assertEq(surplus, 100e18, "Surplus should be 100 tokens");
    }

    function testGetSurplusWithNoSurplus() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal accounting matches vault balance
        uint256 clientInternalBalance = 1000e18;

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            clientInternalBalance
        );

        // Surplus should be 0
        assertEq(surplus, 0, "Surplus should be 0 when balances match");
    }

    function testGetSurplusWithNegativeDifference() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal accounting shows more than vault (edge case)
        uint256 clientInternalBalance = 1100e18;

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            clientInternalBalance
        );

        // Surplus should be 0 (can't be negative)
        assertEq(surplus, 0, "Surplus should be 0 when internal > vault");
    }

    function testGetSurplusWithZeroVaultBalance() public {
        // Client has nothing in vault
        uint256 clientInternalBalance = 0;

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            clientInternalBalance
        );

        // Surplus should be 0
        assertEq(surplus, 0, "Surplus should be 0 with zero vault balance");
    }

    function testGetSurplusWithZeroInternalBalance() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal accounting is 0 (all is surplus)
        uint256 clientInternalBalance = 0;

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            clientInternalBalance
        );

        // Surplus should be entire vault balance
        assertEq(surplus, 1000e18, "Surplus should be entire vault balance");
    }

    // ============ VALIDATION TESTS ============

    function testGetSurplusRevertsWithZeroVault() public {
        vm.expectRevert("SurplusTracker: vault cannot be zero address");
        tracker.getSurplus(address(0), address(token), client, 1000e18);
    }

    function testGetSurplusRevertsWithZeroToken() public {
        vm.expectRevert("SurplusTracker: token cannot be zero address");
        tracker.getSurplus(address(vault), address(0), client, 1000e18);
    }

    function testGetSurplusRevertsWithZeroClient() public {
        vm.expectRevert("SurplusTracker: client cannot be zero address");
        tracker.getSurplus(address(vault), address(token), address(0), 1000e18);
    }

    // ============ PRECISION TESTS ============

    function testGetSurplusWithSmallAmounts() public {
        // Setup: Client has 1 wei in vault
        vm.startPrank(client);
        token.approve(address(vault), 1);
        vault.deposit(address(token), 1, client);
        vm.stopPrank();

        // Client's internal accounting is 0
        uint256 clientInternalBalance = 0;

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            clientInternalBalance
        );

        // Surplus should be 1 wei
        assertEq(surplus, 1, "Surplus should handle 1 wei correctly");
    }

    function testGetSurplusWithLargeAmounts() public {
        // Setup: Client has max uint256/2 tokens in vault
        uint256 largeAmount = type(uint256).max / 2;
        token.mint(client, largeAmount);

        vm.startPrank(client);
        token.approve(address(vault), largeAmount);
        vault.deposit(address(token), largeAmount, client);
        vm.stopPrank();

        // Client's internal accounting is half
        uint256 clientInternalBalance = largeAmount / 2;

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            clientInternalBalance
        );

        // Surplus should be largeAmount - (largeAmount/2)
        assertEq(surplus, largeAmount - clientInternalBalance, "Surplus should handle large amounts");
    }

    function testGetSurplusWithMaxInternalBalance() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal accounting is max uint256 (edge case)
        uint256 clientInternalBalance = type(uint256).max;

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            clientInternalBalance
        );

        // Surplus should be 0 (vault balance < internal)
        assertEq(surplus, 0, "Surplus should be 0 when internal is max");
    }

    // ============ MULTIPLE CLIENT TESTS ============

    function testGetSurplusWithMultipleClients() public {
        address client2 = address(0x3);
        vault.setClient(client2, true);
        token.mint(client2, 10000e18);

        // Setup: Client 1 has 1000 tokens
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Setup: Client 2 has 2000 tokens
        vm.startPrank(client2);
        token.approve(address(vault), 2000e18);
        vault.deposit(address(token), 2000e18, client2);
        vm.stopPrank();

        // Calculate surplus for both clients
        uint256 surplus1 = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            900e18 // Client 1 internal: 900
        );

        uint256 surplus2 = tracker.getSurplus(
            address(vault),
            address(token),
            client2,
            1800e18 // Client 2 internal: 1800
        );

        // Verify independent surplus calculations
        assertEq(surplus1, 100e18, "Client 1 surplus should be 100");
        assertEq(surplus2, 200e18, "Client 2 surplus should be 200");
    }

    // ============ EDGE CASE TESTS ============

    function testGetSurplusAfterPartialWithdrawal() public {
        // Setup: Client deposits 1000 tokens
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client withdraws 200 tokens
        vm.prank(client);
        vault.withdraw(address(token), 200e18, recipient);

        // Vault now has 800 tokens for client
        // Client's internal accounting shows 750 (some yield accrued)
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            750e18
        );

        // Surplus should be 800 - 750 = 50
        assertEq(surplus, 50e18, "Surplus should be correct after withdrawal");
    }

    function testGetSurplusWithDifferentTokens() public {
        MockERC20 token2 = new MockERC20("Token 2", "TK2", 18);
        token2.mint(client, 10000e18);

        // Setup: Client deposits different amounts in different tokens
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);

        token2.approve(address(vault), 2000e18);
        vault.deposit(address(token2), 2000e18, client);
        vm.stopPrank();

        // Calculate surplus for each token independently
        uint256 surplus1 = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            900e18
        );

        uint256 surplus2 = tracker.getSurplus(
            address(vault),
            address(token2),
            client,
            1900e18
        );

        // Verify independent calculations
        assertEq(surplus1, 100e18, "Token 1 surplus should be 100");
        assertEq(surplus2, 100e18, "Token 2 surplus should be 100");
    }

    // ============ READ-ONLY VERIFICATION TESTS ============

    function testGetSurplusIsViewFunction() public view {
        // This test verifies that getSurplus is a view function
        // by calling it in a view context
        tracker.getSurplus(
            address(vault),
            address(token),
            client,
            1000e18
        );
        // If this compiles and runs, getSurplus is properly view/pure
    }

    function testGetSurplusDoesNotModifyState() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        uint256 vaultBalanceBefore = vault.balanceOf(address(token), client);

        // Call getSurplus
        tracker.getSurplus(
            address(vault),
            address(token),
            client,
            900e18
        );

        uint256 vaultBalanceAfter = vault.balanceOf(address(token), client);

        // Verify state hasn't changed
        assertEq(vaultBalanceBefore, vaultBalanceAfter, "Vault balance should not change");
    }

    // ============ FUZZ TESTS ============

    function testFuzzGetSurplus(
        uint96 vaultAmount,
        uint96 internalAmount
    ) public {
        // Bound inputs to reasonable values
        vm.assume(vaultAmount > 0);
        vm.assume(vaultAmount <= type(uint96).max);

        // Setup: Client deposits vaultAmount
        token.mint(client, vaultAmount);
        vm.startPrank(client);
        token.approve(address(vault), vaultAmount);
        vault.deposit(address(token), vaultAmount, client);
        vm.stopPrank();

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(vault),
            address(token),
            client,
            internalAmount
        );

        // Verify logic
        if (vaultAmount > internalAmount) {
            assertEq(surplus, vaultAmount - internalAmount, "Surplus should be difference");
        } else {
            assertEq(surplus, 0, "Surplus should be 0 when vault <= internal");
        }
    }
}
