// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/SurplusWithdrawer.sol";
import "../src/SurplusTracker.sol";
import "../src/mocks/MockVault.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title SurplusWithdrawerTest
 * @notice Comprehensive unit tests for SurplusWithdrawer contract
 */
contract SurplusWithdrawerTest is Test {
    SurplusWithdrawer public withdrawer;
    SurplusTracker public tracker;
    MockVault public vault;
    MockERC20 public token;

    address public owner;
    address public client;
    address public recipient;
    address public nonOwner;

    event SurplusWithdrawn(
        address indexed vault,
        address indexed token,
        address indexed client,
        uint256 percentage,
        uint256 amount,
        address recipient
    );

    function setUp() public {
        owner = address(this);
        client = address(0x1);
        recipient = address(0x2);
        nonOwner = address(0x3);

        // Deploy contracts
        tracker = new SurplusTracker();
        withdrawer = new SurplusWithdrawer(address(tracker), owner);
        vault = new MockVault(owner);
        token = new MockERC20("Test Token", "TEST", 18);

        // Setup vault
        vault.setClient(client, true);
        vault.setWithdrawer(address(withdrawer), true);

        // Mint tokens to client for testing
        token.mint(client, 10000e18);
    }

    // ============ CONSTRUCTOR TESTS ============

    function testConstructorWithValidInputs() public {
        SurplusWithdrawer newWithdrawer = new SurplusWithdrawer(address(tracker), owner);
        assertEq(address(newWithdrawer.surplusTracker()), address(tracker), "Tracker should be set");
        assertEq(newWithdrawer.owner(), owner, "Owner should be set");
    }

    function testConstructorRevertsWithZeroTracker() public {
        vm.expectRevert("SurplusWithdrawer: tracker cannot be zero address");
        new SurplusWithdrawer(address(0), owner);
    }

    function testConstructorRevertsWithZeroOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new SurplusWithdrawer(address(tracker), address(0));
    }

    // ============ PERCENTAGE VALIDATION TESTS ============

    function testWithdrawSurplusPercentRevertsWithZeroPercentage() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 900 (100 surplus)
        uint256 clientInternalBalance = 900e18;

        // Try to withdraw 0%
        vm.expectRevert("SurplusWithdrawer: percentage must be between 1 and 100");
        withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            0,
            recipient
        );
    }

    function testWithdrawSurplusPercentRevertsWithPercentageOver100() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 900 (100 surplus)
        uint256 clientInternalBalance = 900e18;

        // Try to withdraw 101%
        vm.expectRevert("SurplusWithdrawer: percentage must be between 1 and 100");
        withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            101,
            recipient
        );
    }

    function testWithdrawSurplusPercentRevertsWithPercentage200() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 900 (100 surplus)
        uint256 clientInternalBalance = 900e18;

        // Try to withdraw 200%
        vm.expectRevert("SurplusWithdrawer: percentage must be between 1 and 100");
        withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            200,
            recipient
        );
    }

    function testWithdrawSurplusPercentAllowsPercentage1() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 900 (100 surplus)
        uint256 clientInternalBalance = 900e18;

        // Withdraw 1% (boundary test)
        uint256 amount = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            1,
            recipient
        );

        // 1% of 100 = 1
        assertEq(amount, 1e18, "Should withdraw 1% of surplus");
        assertEq(token.balanceOf(recipient), 1e18, "Recipient should receive 1 token");
    }

    function testWithdrawSurplusPercentAllowsPercentage100() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 900 (100 surplus)
        uint256 clientInternalBalance = 900e18;

        // Withdraw 100% (boundary test)
        uint256 amount = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            100,
            recipient
        );

        // 100% of 100 = 100
        assertEq(amount, 100e18, "Should withdraw 100% of surplus");
        assertEq(token.balanceOf(recipient), 100e18, "Recipient should receive 100 tokens");
    }

    // ============ PERCENTAGE CALCULATION TESTS ============

    function testWithdrawSurplusPercent50Percent() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 800 (200 surplus)
        uint256 clientInternalBalance = 800e18;

        // Withdraw 50%
        uint256 amount = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            50,
            recipient
        );

        // 50% of 200 = 100
        assertEq(amount, 100e18, "Should withdraw 50% of surplus");
        assertEq(token.balanceOf(recipient), 100e18, "Recipient should receive 100 tokens");
    }

    function testWithdrawSurplusPercent25Percent() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 600 (400 surplus)
        uint256 clientInternalBalance = 600e18;

        // Withdraw 25%
        uint256 amount = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            25,
            recipient
        );

        // 25% of 400 = 100
        assertEq(amount, 100e18, "Should withdraw 25% of surplus");
        assertEq(token.balanceOf(recipient), 100e18, "Recipient should receive 100 tokens");
    }

    function testWithdrawSurplusPercent75Percent() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 600 (400 surplus)
        uint256 clientInternalBalance = 600e18;

        // Withdraw 75%
        uint256 amount = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            75,
            recipient
        );

        // 75% of 400 = 300
        assertEq(amount, 300e18, "Should withdraw 75% of surplus");
        assertEq(token.balanceOf(recipient), 300e18, "Recipient should receive 300 tokens");
    }

    function testWithdrawSurplusPercentWithLargeSurplus() public {
        // Setup: Client has 10000 tokens in vault (large amount)
        vm.startPrank(client);
        token.approve(address(vault), 10000e18);
        vault.deposit(address(token), 10000e18, client);
        vm.stopPrank();

        // Client's internal balance is 5000 (5000 surplus)
        uint256 clientInternalBalance = 5000e18;

        // Withdraw 30%
        uint256 amount = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            30,
            recipient
        );

        // 30% of 5000 = 1500
        assertEq(amount, 1500e18, "Should withdraw 30% of surplus");
        assertEq(token.balanceOf(recipient), 1500e18, "Recipient should receive 1500 tokens");
    }

    function testWithdrawSurplusPercentWithSmallSurplus() public {
        // Setup: Client has 110 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 110e18);
        vault.deposit(address(token), 110e18, client);
        vm.stopPrank();

        // Client's internal balance is 100 (10 surplus)
        uint256 clientInternalBalance = 100e18;

        // Withdraw 50%
        uint256 amount = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            50,
            recipient
        );

        // 50% of 10 = 5
        assertEq(amount, 5e18, "Should withdraw 50% of surplus");
        assertEq(token.balanceOf(recipient), 5e18, "Recipient should receive 5 tokens");
    }

    // ============ INPUT VALIDATION TESTS ============

    function testWithdrawSurplusPercentRevertsWithZeroVault() public {
        vm.expectRevert("SurplusWithdrawer: vault cannot be zero address");
        withdrawer.withdrawSurplusPercent(
            address(0),
            address(token),
            client,
            100e18,
            50,
            recipient
        );
    }

    function testWithdrawSurplusPercentRevertsWithZeroToken() public {
        vm.expectRevert("SurplusWithdrawer: token cannot be zero address");
        withdrawer.withdrawSurplusPercent(
            address(vault),
            address(0),
            client,
            100e18,
            50,
            recipient
        );
    }

    function testWithdrawSurplusPercentRevertsWithZeroClient() public {
        vm.expectRevert("SurplusWithdrawer: client cannot be zero address");
        withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            address(0),
            100e18,
            50,
            recipient
        );
    }

    function testWithdrawSurplusPercentRevertsWithZeroRecipient() public {
        // Setup: Client has tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        vm.expectRevert("SurplusWithdrawer: recipient cannot be zero address");
        withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            900e18,
            50,
            address(0)
        );
    }

    function testWithdrawSurplusPercentRevertsWithNoSurplus() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance matches vault balance (no surplus)
        uint256 clientInternalBalance = 1000e18;

        vm.expectRevert("SurplusWithdrawer: no surplus to withdraw");
        withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            50,
            recipient
        );
    }

    // ============ ACCESS CONTROL TESTS ============

    function testWithdrawSurplusPercentRevertsWhenCalledByNonOwner() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 900 (100 surplus)
        uint256 clientInternalBalance = 900e18;

        // Try to withdraw as non-owner
        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            50,
            recipient
        );
        vm.stopPrank();
    }

    function testWithdrawSurplusPercentSucceedsWhenCalledByOwner() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 900 (100 surplus)
        uint256 clientInternalBalance = 900e18;

        // Withdraw as owner (owner is address(this))
        uint256 amount = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            50,
            recipient
        );

        assertEq(amount, 50e18, "Should withdraw 50% of surplus");
    }

    // ============ EVENT TESTS ============

    function testWithdrawSurplusPercentEmitsEvent() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 800 (200 surplus)
        uint256 clientInternalBalance = 800e18;

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit SurplusWithdrawn(
            address(vault),
            address(token),
            client,
            50,
            100e18,
            recipient
        );

        // Withdraw 50%
        withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            50,
            recipient
        );
    }

    // ============ INTEGRATION TESTS ============

    function testWithdrawSurplusPercentUpdatesVaultBalance() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 900 (100 surplus)
        uint256 clientInternalBalance = 900e18;

        // Get initial vault balance
        uint256 initialVaultBalance = vault.balanceOf(address(token), client);
        assertEq(initialVaultBalance, 1000e18, "Initial vault balance should be 1000");

        // Withdraw 50% of surplus
        uint256 amount = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            50,
            recipient
        );

        // Get final vault balance
        uint256 finalVaultBalance = vault.balanceOf(address(token), client);

        // Vault balance should decrease by withdrawal amount
        assertEq(finalVaultBalance, initialVaultBalance - amount, "Vault balance should decrease by withdrawal amount");
        assertEq(finalVaultBalance, 950e18, "Vault balance should be 950");
    }

    function testMultipleWithdrawalsReduceSurplus() public {
        // Setup: Client has 1000 tokens in vault
        vm.startPrank(client);
        token.approve(address(vault), 1000e18);
        vault.deposit(address(token), 1000e18, client);
        vm.stopPrank();

        // Client's internal balance is 800 (200 surplus)
        uint256 clientInternalBalance = 800e18;

        // First withdrawal: 25% of 200 = 50
        uint256 amount1 = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            25,
            recipient
        );
        assertEq(amount1, 50e18, "First withdrawal should be 50");

        // After first withdrawal: vault balance = 950, surplus = 150
        uint256 surplus1 = tracker.getSurplus(address(vault), address(token), client, clientInternalBalance);
        assertEq(surplus1, 150e18, "Surplus after first withdrawal should be 150");

        // Second withdrawal: 50% of 150 = 75
        uint256 amount2 = withdrawer.withdrawSurplusPercent(
            address(vault),
            address(token),
            client,
            clientInternalBalance,
            50,
            recipient
        );
        assertEq(amount2, 75e18, "Second withdrawal should be 75");

        // After second withdrawal: vault balance = 875, surplus = 75
        uint256 surplus2 = tracker.getSurplus(address(vault), address(token), client, clientInternalBalance);
        assertEq(surplus2, 75e18, "Surplus after second withdrawal should be 75");

        // Total withdrawn should be 125
        assertEq(token.balanceOf(recipient), 125e18, "Total withdrawn should be 125");
    }
}
