// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "../../src/mocks/MockAutoDOLA.sol";
import "../../src/mocks/MockMainRewarder.sol";

/**
 * @title AutoDolaYieldStrategyUnitTest
 * @notice Comprehensive unit tests for principalOf, totalBalanceOf, and balanceOf methods
 */
contract AutoDolaYieldStrategyUnitTest is Test {
    AutoDolaYieldStrategy vault;
    MockERC20 dolaToken;
    MockERC20 tokeToken;
    MockAutoDOLA autoDolaVault;
    MockMainRewarder mainRewarder;

    address owner = address(0x1234);
    address client = address(0x5678);
    address user1 = address(0xDEF0);
    address user2 = address(0x1357);
    address user3 = address(0x2468);

    uint256 constant INITIAL_DOLA_SUPPLY = 10000000e18; // 10M DOLA
    uint256 constant INITIAL_TOKE_SUPPLY = 1000000e18;  // 1M TOKE

    function setUp() public {
        // Deploy mock tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock MainRewarder
        mainRewarder = new MockMainRewarder(address(tokeToken));

        // Deploy mock autoDOLA vault
        autoDolaVault = new MockAutoDOLA(address(dolaToken), address(mainRewarder));

        // Deploy the vault
        vm.prank(owner);
        vault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Mint tokens
        dolaToken.mint(client, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(address(autoDolaVault), INITIAL_DOLA_SUPPLY); // For autoDOLA mock
        tokeToken.mint(address(mainRewarder), INITIAL_TOKE_SUPPLY);

        // Authorize client
        vm.prank(owner);
        vault.setClient(client, true);
    }

    // ============ principalOf() TESTS ============

    function testPrincipalOfSingleUser() public {
        uint256 depositAmount = 1000e18;

        // Deposit
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Test principalOf returns correct balance
        assertEq(vault.principalOf(address(dolaToken), user1), depositAmount);
        assertEq(vault.principalOf(address(dolaToken), user2), 0);
    }

    function testPrincipalOfMultipleUsers() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;
        uint256 deposit3 = 3000e18;

        // Deposit for user1
        vm.prank(client);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit1, user1);

        // Deposit for user2
        vm.prank(client);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit2, user2);

        // Deposit for user3
        vm.prank(client);
        dolaToken.approve(address(vault), deposit3);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit3, user3);

        // Verify each user's principal
        assertEq(vault.principalOf(address(dolaToken), user1), deposit1);
        assertEq(vault.principalOf(address(dolaToken), user2), deposit2);
        assertEq(vault.principalOf(address(dolaToken), user3), deposit3);
    }

    function testPrincipalOfZeroBalance() public {
        // Test account with no deposits
        assertEq(vault.principalOf(address(dolaToken), user1), 0);
    }

    function testPrincipalOfUnsupportedToken() public {
        // Test with non-DOLA token
        vm.expectRevert("AutoDolaYieldStrategy: only DOLA token supported");
        vault.principalOf(address(tokeToken), user1);
    }

    function testPrincipalOfAfterPartialWithdrawal() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 400e18;

        // Deposit
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, client);

        // Withdraw
        vm.prank(client);
        vault.withdraw(address(dolaToken), withdrawAmount, client);

        // Principal should be reduced
        assertEq(vault.principalOf(address(dolaToken), client), depositAmount - withdrawAmount);
    }

    // ============ totalBalanceOf() TESTS ============

    function testTotalBalanceOfNoYield() public {
        uint256 depositAmount = 1000e18;

        // Deposit
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // With no yield, totalBalanceOf should equal principalOf
        assertEq(vault.totalBalanceOf(address(dolaToken), user1), depositAmount);
        assertEq(vault.totalBalanceOf(address(dolaToken), user1), vault.principalOf(address(dolaToken), user1));
    }

    function testTotalBalanceOfWithYield() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;

        // Deposit for user1
        vm.prank(client);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit1, user1);

        // Deposit for user2
        vm.prank(client);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit2, user2);

        // Simulate yield using the mock's simulateYield function
        uint256 yieldAmount = 300e18;
        autoDolaVault.simulateYield(yieldAmount);

        // Total vault value is now 3000 + 300 = 3300
        // User1 should get 1000/3000 * 3300 = 1100
        // User2 should get 2000/3000 * 3300 = 2200

        uint256 user1Total = vault.totalBalanceOf(address(dolaToken), user1);
        uint256 user2Total = vault.totalBalanceOf(address(dolaToken), user2);

        // Check that totalBalanceOf is greater than principal
        assertGt(user1Total, vault.principalOf(address(dolaToken), user1));
        assertGt(user2Total, vault.principalOf(address(dolaToken), user2));

        // Check proportional distribution (with 1 wei tolerance for rounding)
        assertApproxEqAbs(user1Total, 1100e18, 1);
        assertApproxEqAbs(user2Total, 2200e18, 1);
    }

    function testTotalBalanceOfProportionalDistribution() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 4000e18; // 4x user1

        // Deposit for user1
        vm.prank(client);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit1, user1);

        // Deposit for user2
        vm.prank(client);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit2, user2);

        // Simulate 50% yield (5000 total becomes 7500)
        uint256 yieldAmount = 2500e18;
        autoDolaVault.simulateYield(yieldAmount);

        uint256 user1Total = vault.totalBalanceOf(address(dolaToken), user1);
        uint256 user2Total = vault.totalBalanceOf(address(dolaToken), user2);

        // User2 should have 4x user1's total balance (both principal and yield are proportional)
        assertApproxEqAbs(user2Total, user1Total * 4, 1);
    }

    function testTotalBalanceOfZeroPrincipal() public {
        // Account with no deposits should have zero totalBalanceOf
        assertEq(vault.totalBalanceOf(address(dolaToken), user1), 0);
    }

    function testTotalBalanceOfZeroTotalDeposited() public {
        // Edge case: totalDeposited is zero
        assertEq(vault.totalBalanceOf(address(dolaToken), user1), 0);
    }

    function testTotalBalanceOfUnsupportedToken() public {
        vm.expectRevert("AutoDolaYieldStrategy: only DOLA token supported");
        vault.totalBalanceOf(address(tokeToken), user1);
    }

    function testTotalBalanceOfPrecisionRounding() public {
        // Test with small amounts to check rounding behavior
        uint256 deposit1 = 1; // 1 wei
        uint256 deposit2 = 2; // 2 wei

        vm.prank(client);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit1, user1);

        vm.prank(client);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit2, user2);

        // Add yield
        autoDolaVault.simulateYield(3);

        // Total is now 6 wei
        // User1: 1/3 * 6 = 2 wei
        // User2: 2/3 * 6 = 4 wei
        uint256 user1Total = vault.totalBalanceOf(address(dolaToken), user1);
        uint256 user2Total = vault.totalBalanceOf(address(dolaToken), user2);

        // Allow 1 wei rounding tolerance
        assertApproxEqAbs(user1Total, 2, 1);
        assertApproxEqAbs(user2Total, 4, 1);
    }

    function testTotalBalanceOfSumEqualsVaultValue() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;
        uint256 deposit3 = 3000e18;

        // Three users deposit
        vm.prank(client);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit1, user1);

        vm.prank(client);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit2, user2);

        vm.prank(client);
        dolaToken.approve(address(vault), deposit3);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit3, user3);

        // Add yield
        uint256 yieldAmount = 600e18;
        autoDolaVault.simulateYield(yieldAmount);

        // Sum of all totalBalanceOf should equal total vault value
        uint256 user1Total = vault.totalBalanceOf(address(dolaToken), user1);
        uint256 user2Total = vault.totalBalanceOf(address(dolaToken), user2);
        uint256 user3Total = vault.totalBalanceOf(address(dolaToken), user3);
        uint256 sumTotal = user1Total + user2Total + user3Total;

        // Get actual vault value
        uint256 totalShares = autoDolaVault.balanceOf(address(vault));
        uint256 totalValue = autoDolaVault.convertToAssets(totalShares);

        // Sum should equal total vault value (within rounding tolerance)
        assertApproxEqAbs(sumTotal, totalValue, 3); // 3 wei tolerance for 3 users
    }

    // ============ balanceOf() BACKWARD COMPATIBILITY TESTS ============

    function testBalanceOfDelegatesToPrincipalOf() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // balanceOf should return the same as principalOf
        assertEq(vault.balanceOf(address(dolaToken), user1), vault.principalOf(address(dolaToken), user1));
    }

    function testBalanceOfReturnsPrincipalNotTotal() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Add yield
        autoDolaVault.simulateYield(100e18);

        // balanceOf should return principal, not total (backward compatibility)
        assertEq(vault.balanceOf(address(dolaToken), user1), depositAmount);
        assertEq(vault.balanceOf(address(dolaToken), user1), vault.principalOf(address(dolaToken), user1));
        assertLt(vault.balanceOf(address(dolaToken), user1), vault.totalBalanceOf(address(dolaToken), user1));
    }

    function testBalanceOfBackwardCompatibilityMultipleUsers() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;

        vm.prank(client);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit1, user1);

        vm.prank(client);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit2, user2);

        // Verify balanceOf matches principalOf for all users
        assertEq(vault.balanceOf(address(dolaToken), user1), vault.principalOf(address(dolaToken), user1));
        assertEq(vault.balanceOf(address(dolaToken), user2), vault.principalOf(address(dolaToken), user2));
        assertEq(vault.balanceOf(address(dolaToken), user1), deposit1);
        assertEq(vault.balanceOf(address(dolaToken), user2), deposit2);
    }

    // ============ INTEGRATION SCENARIOS ============

    function testMultipleUsersWithDifferentPrincipals() public {
        // Scenario: Multiple users with different deposit amounts, varying yield
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = 500e18;  // user1
        deposits[1] = 1500e18; // user2
        deposits[2] = 3000e18; // user3

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        // Deposits
        for (uint i = 0; i < users.length; i++) {
            vm.prank(client);
            dolaToken.approve(address(vault), deposits[i]);
            vm.prank(client);
            vault.deposit(address(dolaToken), deposits[i], users[i]);
        }

        // Verify principals
        for (uint i = 0; i < users.length; i++) {
            assertEq(vault.principalOf(address(dolaToken), users[i]), deposits[i]);
        }

        // Add 40% yield (5000 total becomes 7000)
        autoDolaVault.simulateYield(2000e18);

        // Verify totalBalanceOf proportions
        for (uint i = 0; i < users.length; i++) {
            uint256 expectedTotal = (deposits[i] * 7000e18) / 5000e18;
            assertApproxEqAbs(vault.totalBalanceOf(address(dolaToken), users[i]), expectedTotal, 1);
        }
    }

    function testVaultAppreciationScenario() public {
        // Scenario: Vault appreciates over time
        uint256 deposit = 1000e18;

        vm.prank(client);
        dolaToken.approve(address(vault), deposit);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit, user1);

        // Initial state: no yield
        assertEq(vault.principalOf(address(dolaToken), user1), deposit);
        assertEq(vault.totalBalanceOf(address(dolaToken), user1), deposit);

        // First yield event: +10%
        autoDolaVault.simulateYield(100e18);
        assertEq(vault.principalOf(address(dolaToken), user1), deposit);
        assertApproxEqAbs(vault.totalBalanceOf(address(dolaToken), user1), 1100e18, 1);

        // Second yield event: another +10% (total 21%)
        autoDolaVault.simulateYield(110e18);
        assertEq(vault.principalOf(address(dolaToken), user1), deposit);
        assertApproxEqAbs(vault.totalBalanceOf(address(dolaToken), user1), 1210e18, 1);
    }

    function testAfterWithdrawalYieldCalculation() public {
        uint256 deposit1 = 2000e18;
        uint256 deposit2 = 2000e18;

        // Two users deposit equal amounts
        // NOTE: In AutoDolaYieldStrategy, the balance is tracked under the CLIENT, not the recipient
        // So we need to deposit for client, not for user1/user2
        vm.prank(client);
        dolaToken.approve(address(vault), deposit1 + deposit2);
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit1, client);

        // Add yield
        autoDolaVault.simulateYield(200e18); // 10% yield on first deposit

        // Client deposits more (simulating second user behavior)
        vm.prank(client);
        vault.deposit(address(dolaToken), deposit2, client);

        // Add more yield
        autoDolaVault.simulateYield(200e18); // Additional yield

        // Client withdraws part of their principal
        vm.prank(client);
        vault.withdraw(address(dolaToken), deposit1, client);

        // Client should have reduced balance
        assertEq(vault.principalOf(address(dolaToken), client), deposit2);

        // totalBalanceOf should reflect remaining principal plus proportional yield
        uint256 totalShares = autoDolaVault.balanceOf(address(vault));
        uint256 totalValue = autoDolaVault.convertToAssets(totalShares);
        assertApproxEqAbs(vault.totalBalanceOf(address(dolaToken), client), totalValue, 1);
    }
}
