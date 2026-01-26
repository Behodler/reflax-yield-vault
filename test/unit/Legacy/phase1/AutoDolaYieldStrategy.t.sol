// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../../../src/concreteYieldStrategies/Legacy/phase1/AutoDolaYieldStrategy.sol";
import "../../../../src/mocks/MockERC20.sol";
import "../../../../src/mocks/MockAutoDOLA.sol";
import "../../../../src/mocks/MockMainRewarder.sol";

/**
 * @title AutoDolaYieldStrategyLegacyTest
 * @notice Unit tests for the legacy AutoDolaYieldStrategy implementation
 * @dev This test file preserves test coverage for the phase1 legacy implementation
 *      Legacy contracts are kept for mainnet compatibility with existing deployments
 */
contract AutoDolaYieldStrategyLegacyTest is Test {
    AutoDolaYieldStrategy vault;
    MockERC20 dolaToken;
    MockERC20 tokeToken;
    MockAutoDOLA autoDolaVault;
    MockMainRewarder mainRewarder;

    address owner = address(0x1234);
    address client = address(0x5678);
    address user1 = address(0xDEF0);
    address user2 = address(0x1357);

    uint256 constant INITIAL_DOLA_SUPPLY = 10000000e18; // 10M DOLA
    uint256 constant INITIAL_TOKE_SUPPLY = 1000000e18; // 1M TOKE

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
            owner, address(dolaToken), address(tokeToken), address(autoDolaVault), address(mainRewarder)
        );

        // Mint tokens
        dolaToken.mint(client, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(address(autoDolaVault), INITIAL_DOLA_SUPPLY); // For autoDOLA mock
        tokeToken.mint(address(mainRewarder), INITIAL_TOKE_SUPPLY);

        // Authorize client
        vm.prank(owner);
        vault.setClient(client, true);
    }

    /**
     * @notice Test basic deposit functionality for legacy AutoDolaYieldStrategy
     */
    function testLegacyDeposit() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Verify balance tracked correctly
        assertEq(vault.balanceOf(address(dolaToken), user1), depositAmount);
    }

    /**
     * @notice Test basic withdrawal functionality for legacy AutoDolaYieldStrategy
     */
    function testLegacyWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 400e18;

        // Deposit first
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, client);

        // Withdraw
        vm.prank(client);
        vault.withdraw(address(dolaToken), withdrawAmount, client);

        // Verify balance reduced correctly
        assertEq(vault.balanceOf(address(dolaToken), client), depositAmount - withdrawAmount);
    }

    /**
     * @notice Test principalOf returns correct value for legacy implementation
     */
    function testLegacyPrincipalOf() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        assertEq(vault.principalOf(address(dolaToken), user1), depositAmount);
    }

    /**
     * @notice Test totalBalanceOf includes yield for legacy implementation
     */
    function testLegacyTotalBalanceOfWithYield() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Simulate yield
        uint256 yieldAmount = 100e18;
        autoDolaVault.simulateYield(yieldAmount);

        // totalBalanceOf should include yield
        uint256 totalBalance = vault.totalBalanceOf(address(dolaToken), user1);
        assertGt(totalBalance, depositAmount);
        assertApproxEqAbs(totalBalance, depositAmount + yieldAmount, 1);
    }

    /**
     * @notice Test that legacy implementation can be imported from Legacy path
     */
    function testLegacyImportPath() public view {
        // This test verifies the contract can be imported from the Legacy path
        // If this compiles and runs, the import path is correct
        assertTrue(address(vault) != address(0));
        assertEq(vault.owner(), owner);
    }

    /**
     * @notice Test TOKE reward claiming for legacy implementation
     */
    function testLegacyTokeRewardsClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 rewardAmount = 50e18;

        // Deposit to enable staking
        vm.prank(client);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Verify rewards are available
        assertEq(vault.getTokeRewards(), rewardAmount);

        // Owner claims rewards
        uint256 initialTokeBalance = tokeToken.balanceOf(user1);
        vm.prank(owner);
        vault.claimTokeRewards(user1);

        // Verify rewards transferred
        assertEq(tokeToken.balanceOf(user1), initialTokeBalance + rewardAmount);
    }
}
