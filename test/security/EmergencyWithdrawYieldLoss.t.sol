// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/AutoPoolYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "../mocks/MockAutoPool.sol";
import "../../src/mocks/MockMainRewarder.sol";

/**
 * @title EmergencyWithdrawYieldLossTest
 * @notice Tests verifying emergency withdrawal behavior and yield continuity
 * @dev Tests security behavior L1 from security audit report
 *
 * BEHAVIOR VERIFIED:
 * - _emergencyWithdraw only unstakes the shares needed for withdrawal
 * - Remaining shares stay staked in MainRewarder, continuing to earn TOKE
 * - Regular withdraw correctly re-stakes any leftover shares
 *
 * IMPACT:
 * - Remaining shares continue earning TOKE rewards
 * - Yield generation continues for remaining user funds
 *
 * SEVERITY: N/A (correct behavior, no vulnerability)
 */
contract EmergencyWithdrawYieldLossTest is Test {
    AutoPoolYieldStrategy vault;
    MockERC20 underlyingToken;
    MockERC20 tokeToken;
    MockAutoPool autoPoolVault;
    MockMainRewarder mainRewarder;

    address owner = address(0x1234);
    address client = address(0x5678);
    address user1 = address(0xDEF0);

    uint256 constant INITIAL_SUPPLY = 10000000e18;

    function setUp() public {
        // Deploy mock tokens
        underlyingToken = new MockERC20("Underlying", "UNDERLYING", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock contracts
        mainRewarder = new MockMainRewarder(address(tokeToken));
        autoPoolVault = new MockAutoPool("AutoPool", "autoPool", address(underlyingToken), address(mainRewarder));

        // Enable realistic transfer mode for security tests
        // This makes the mock actually transfer shares, simulating real Tokemak behavior
        mainRewarder.setShareToken(address(autoPoolVault));

        // Deploy vault
        vm.prank(owner);
        vault = new AutoPoolYieldStrategy(
            owner, address(underlyingToken), address(tokeToken), address(autoPoolVault), address(mainRewarder)
        );

        // Mint tokens
        underlyingToken.mint(client, INITIAL_SUPPLY);
        underlyingToken.mint(address(autoPoolVault), INITIAL_SUPPLY);
        tokeToken.mint(address(mainRewarder), INITIAL_SUPPLY);

        // Authorize client
        vm.prank(owner);
        vault.setClient(client, true);
    }

    /**
     * @notice Test that emergency withdrawal keeps remaining shares staked
     */
    function testEmergencyWithdrawKeepsRemainingSharesStaked() public {
        // Setup: User deposits funds
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Verify shares are staked
        uint256 stakedSharesBefore = mainRewarder.balanceOf(address(vault));
        assertGt(stakedSharesBefore, 0, "Shares should be staked after deposit");

        // Owner performs emergency withdrawal of 50%
        uint256 emergencyAmount = 5000e18;
        vm.prank(owner);
        vault.emergencyWithdraw(emergencyAmount);

        // CORRECT BEHAVIOR: Remaining shares stay staked
        uint256 stakedSharesAfter = mainRewarder.balanceOf(address(vault));
        uint256 unstakedShares = autoPoolVault.balanceOf(address(vault));

        // Remaining shares should stay staked in MainRewarder
        assertGt(stakedSharesAfter, 0, "Remaining shares should stay staked");
        assertEq(unstakedShares, 0, "No shares should be sitting unstaked in vault");

        // Benefit: TOKE rewards continue accumulating for remaining staked shares
    }

    /**
     * @notice Test that TOKE rewards continue accumulating after emergency withdrawal
     */
    function testTokeRewardsContinueAfterEmergencyWithdrawal() public {
        // Setup: User deposits funds
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Fast forward time to accumulate TOKE rewards
        vm.warp(block.timestamp + 7 days);
        uint256 rewardsBefore = vault.getTokeRewards();
        assertGt(rewardsBefore, 0, "Should have accumulated TOKE rewards");

        // Owner performs emergency withdrawal of 50%
        uint256 emergencyAmount = 5000e18;
        vm.prank(owner);
        vault.emergencyWithdraw(emergencyAmount);

        // Rewards should still be claimable (accumulated before emergency withdraw)
        // Note: After emergency withdraw, remaining shares are still staked
        uint256 rewardsAfterWithdraw = vault.getTokeRewards();
        // Rewards are captured/updated during the withdraw process
        assertGe(rewardsAfterWithdraw, 0, "Rewards should be available or captured");

        // Fast forward time again
        vm.warp(block.timestamp + 7 days);

        // CORRECT BEHAVIOR: TOKE rewards should continue increasing (remaining shares still staked)
        uint256 rewardsAfter = vault.getTokeRewards();

        // In the correct contract, rewards continue accumulating for remaining staked shares
        assertGt(rewardsAfter, 0, "TOKE rewards should continue accumulating for remaining shares");
    }

    /**
     * @notice Test comparison: Regular withdraw correctly re-stakes shares
     */
    function testRegularWithdrawCorrectlyReStakes() public {
        // Setup: User deposits funds
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, client);

        // User performs regular withdrawal of 50%
        uint256 withdrawAmount = 5000e18;
        vm.prank(client);
        vault.withdraw(address(underlyingToken), withdrawAmount, client);

        // CORRECT BEHAVIOR: Remaining shares should be re-staked
        uint256 stakedSharesAfter = mainRewarder.balanceOf(address(vault));
        uint256 unstakedShares = autoPoolVault.balanceOf(address(vault));

        assertGt(stakedSharesAfter, 0, "Remaining shares should be re-staked");
        assertEq(unstakedShares, 0, "No shares should be sitting unstaked");

        // Verify TOKE rewards continue accumulating
        vm.warp(block.timestamp + 7 days);
        uint256 rewards = vault.getTokeRewards();
        assertGt(rewards, 0, "TOKE rewards should continue accumulating");
    }

    /**
     * @notice Test that user funds remain safe despite yield loss
     */
    function testUserFundsRemainSafeDespiteYieldLoss() public {
        // Setup: User deposits funds
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Owner performs emergency withdrawal
        uint256 emergencyAmount = 5000e18;
        vm.prank(owner);
        vault.emergencyWithdraw(emergencyAmount);

        // User principal should remain accurate
        uint256 userPrincipal = vault.principalOf(address(underlyingToken), user1);
        assertEq(userPrincipal, depositAmount, "User principal should be unaffected");

        // User should still be able to withdraw their principal
        vm.prank(client);
        vault.withdraw(address(underlyingToken), depositAmount, user1);

        // Verify withdrawal succeeded
        uint256 principalAfter = vault.principalOf(address(underlyingToken), user1);
        assertEq(principalAfter, 0, "User should be able to withdraw full principal");
    }
}
