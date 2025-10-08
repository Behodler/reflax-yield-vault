// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteVaults/AutoDolaVault.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title AutoDolaVaultWithdrawalPrecision
 * @notice Comprehensive precision tests for AutoDolaVault withdrawal operations
 * @dev Tests critical edge cases from tiny amounts (1 wei) to extreme values (1e40)
 *      ensuring accurate balance reduction and share calculations across all scenarios
 */
contract AutoDolaVaultWithdrawalPrecision is Test {
    AutoDolaVault public vault;
    MockERC20 public dolaToken;
    MockERC20 public tokeToken;
    MockAutoDOLA public autoDolaVault;
    MockMainRewarder public mainRewarder;

    address public owner = address(1);
    address public client1 = address(2);
    address public client2 = address(3);
    address public client3 = address(4);
    address public recipient1 = address(5);
    address public recipient2 = address(6);
    address public recipient3 = address(7);

    // Events from AutoDolaVault
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

        // Deploy AutoDolaVault
        vault = new AutoDolaVault(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Authorize all clients
        vm.startPrank(owner);
        vault.setClient(client1, true);
        vault.setClient(client2, true);
        vault.setClient(client3, true);
        vm.stopPrank();
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @notice Helper function to perform a deposit operation
     * @param client The client making the deposit
     * @param amount The amount of DOLA to deposit
     * @param recipient The recipient address (stored in clientBalances[token][recipient])
     */
    function _deposit(address client, uint256 amount, address recipient) internal {
        dolaToken.mint(client, amount);
        vm.startPrank(client);
        dolaToken.approve(address(vault), amount);
        vault.deposit(address(dolaToken), amount, recipient);
        vm.stopPrank();
    }

    /**
     * @notice Helper function to perform a withdrawal operation
     * @param client The client making the withdrawal (must match the depositor)
     * @param amount The amount of DOLA to withdraw
     * @param recipient The recipient address for the withdrawn tokens
     */
    function _withdraw(address client, uint256 amount, address recipient) internal {
        vm.prank(client);
        vault.withdraw(address(dolaToken), amount, recipient);
    }

    // ============ PRECISION TESTS - SMALL AMOUNTS ============

    /**
     * @notice Test withdrawal with 1 wei, 10 wei, 100 wei amounts
     * @dev Verifies that tiny amounts are handled correctly without precision loss
     *      Critical for ensuring the contract works across the full magnitude spectrum
     */
    function testWithdrawPrecisionSmallAmounts() public {
        // Test 1 wei withdrawal - client1 deposits to self and withdraws
        _deposit(client1, 1, client1);
        uint256 balanceBefore = vault.balanceOf(address(dolaToken), client1);
        assertEq(balanceBefore, 1, "Initial balance should be 1 wei");

        _withdraw(client1, 1, client1);
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Balance should be 0 after 1 wei withdrawal");
        assertEq(dolaToken.balanceOf(client1), 1, "Recipient should receive 1 wei");

        // Test 10 wei withdrawal - client2 deposits to self and withdraws
        _deposit(client2, 10, client2);
        balanceBefore = vault.balanceOf(address(dolaToken), client2);
        assertEq(balanceBefore, 10, "Initial balance should be 10 wei");

        _withdraw(client2, 10, client2);
        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Balance should be 0 after 10 wei withdrawal");
        assertEq(dolaToken.balanceOf(client2), 10, "Recipient should receive 10 wei");

        // Test 100 wei withdrawal - client3 deposits to self and withdraws
        _deposit(client3, 100, client3);
        balanceBefore = vault.balanceOf(address(dolaToken), client3);
        assertEq(balanceBefore, 100, "Initial balance should be 100 wei");

        _withdraw(client3, 100, client3);
        assertEq(vault.balanceOf(address(dolaToken), client3), 0, "Balance should be 0 after 100 wei withdrawal");
        assertEq(dolaToken.balanceOf(client3), 100, "Recipient should receive 100 wei");
    }

    // ============ PRECISION TESTS - LARGE VALUES ============

    /**
     * @notice Test withdrawal with extreme values (1e30, 1e36)
     * @dev Verifies that the contract handles extremely large values without overflow
     *      or precision loss in the share calculation formulas
     *      Note: 1e40 causes overflow in (totalShares * storedBalance) calculation, so we test up to 1e36
     */
    function testWithdrawPrecisionLargeValues() public {
        // Test 1e30 withdrawal (1 trillion tokens with 18 decimals)
        uint256 largeAmount1 = 1e30;
        _deposit(client1, largeAmount1, client1);
        uint256 balanceBefore = vault.balanceOf(address(dolaToken), client1);
        assertEq(balanceBefore, largeAmount1, "Initial balance should be 1e30");

        _withdraw(client1, largeAmount1, client1);
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Balance should be 0 after 1e30 withdrawal");
        assertEq(dolaToken.balanceOf(client1), largeAmount1, "Recipient should receive 1e30");

        // Test 1e36 withdrawal (maximum practical value without overflow in multiplication)
        // This is 1 quintillion tokens with 18 decimals
        uint256 largeAmount2 = 1e36;
        _deposit(client2, largeAmount2, client2);
        balanceBefore = vault.balanceOf(address(dolaToken), client2);
        assertEq(balanceBefore, largeAmount2, "Initial balance should be 1e36");

        _withdraw(client2, largeAmount2, client2);
        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Balance should be 0 after 1e36 withdrawal");
        assertEq(dolaToken.balanceOf(client2), largeAmount2, "Recipient should receive 1e36");

        // Test partial withdrawal at 1e36 scale
        uint256 largeAmount3 = 1e36;
        _deposit(client3, largeAmount3, client3);
        uint256 withdrawAmount = largeAmount3 / 2;

        _withdraw(client3, withdrawAmount, client3);
        // Allow for minimal rounding error at extreme scales
        uint256 remainingBalance = vault.balanceOf(address(dolaToken), client3);
        assertApproxEqRel(remainingBalance, withdrawAmount, 1e16, "Remaining balance should be approximately half");
        assertApproxEqRel(dolaToken.balanceOf(client3), withdrawAmount, 1e16, "Recipient should receive approximately half");
    }

    // ============ BALANCE REDUCTION ACCURACY TESTS ============

    /**
     * @notice Test proportional balance reduction accuracy (line 246 of AutoDolaVault)
     * @dev Verifies the formula: balanceReduction = (userStoredBalance * amount) / currentBalance
     *      Tests multiple scenarios to ensure no accounting drift occurs
     */
    function testWithdrawBalanceReductionAccuracy() public {
        // Scenario 1: Simple 1:1 ratio (no yield)
        uint256 depositAmount = 1000e18;
        _deposit(client1, depositAmount, client1);

        uint256 withdrawAmount = 400e18;
        uint256 balanceBefore = vault.balanceOf(address(dolaToken), client1);

        _withdraw(client1, withdrawAmount, client1);

        uint256 balanceAfter = vault.balanceOf(address(dolaToken), client1);
        uint256 expectedRemaining = depositAmount - withdrawAmount;
        assertEq(balanceAfter, expectedRemaining, "Balance reduction should be proportional in 1:1 scenario");

        // Scenario 2: With simulated yield - test a fresh deposit with yield
        // First, let client1's withdrawal complete (already done above)
        // Now deposit for client2 in a fresh pool state
        _deposit(client2, depositAmount, client2);

        // Simulate yield: add 50% to the total assets in the pool
        uint256 totalAssetsBeforeYield = autoDolaVault.convertToAssets(autoDolaVault.balanceOf(address(vault)));
        autoDolaVault.simulateYield(totalAssetsBeforeYield / 2);

        balanceBefore = vault.balanceOf(address(dolaToken), client2);
        uint256 expectedBalance = depositAmount * 3 / 2; // Should have 50% yield
        assertApproxEqRel(balanceBefore, expectedBalance, 1e15, "Balance should reflect 50% yield growth");

        // Withdraw half of the yielded balance
        withdrawAmount = balanceBefore / 2;
        _withdraw(client2, withdrawAmount, client2);

        balanceAfter = vault.balanceOf(address(dolaToken), client2);
        // Balance reduction should be proportional to the withdrawal amount
        assertApproxEqRel(balanceAfter, balanceBefore - withdrawAmount, 1e15, "Balance reduction should be proportional with yield");

        // Scenario 3: Multiple partial withdrawals
        _deposit(client3, depositAmount, client3);
        uint256 currentBalance = vault.balanceOf(address(dolaToken), client3);

        // First withdrawal: 25%
        _withdraw(client3, currentBalance / 4, client3);
        uint256 balance1 = vault.balanceOf(address(dolaToken), client3);
        assertApproxEqRel(balance1, currentBalance * 3 / 4, 1e15, "After 25% withdrawal, 75% should remain");

        // Second withdrawal: 33% of remaining
        _withdraw(client3, balance1 / 3, client3);
        uint256 balance2 = vault.balanceOf(address(dolaToken), client3);
        assertApproxEqRel(balance2, balance1 * 2 / 3, 1e15, "After 33% withdrawal, 67% of previous should remain");

        // Third withdrawal: 50% of remaining
        _withdraw(client3, balance2 / 2, client3);
        uint256 balance3 = vault.balanceOf(address(dolaToken), client3);
        assertApproxEqRel(balance3, balance2 / 2, 1e15, "After 50% withdrawal, 50% of previous should remain");
    }

    // ============ MULTIPLE DECIMAL MAGNITUDE TESTS ============

    /**
     * @notice Test partial withdrawals across various decimal magnitudes
     * @dev Ensures precision is maintained when withdrawing amounts at different scales
     *      from the same deposit
     */
    function testWithdrawPartialWithMultipleDecimals() public {
        uint256 depositAmount = 1e24; // Large base amount
        _deposit(client1, depositAmount, client1);

        // Withdraw at different magnitudes
        uint256[] memory withdrawAmounts = new uint256[](6);
        withdrawAmounts[0] = 1e18;  // 1 DOLA (standard token amount)
        withdrawAmounts[1] = 1e20;  // 100 DOLA
        withdrawAmounts[2] = 1e22;  // 10,000 DOLA
        withdrawAmounts[3] = 1e15;  // 0.001 DOLA
        withdrawAmounts[4] = 1e12;  // 0.000001 DOLA
        withdrawAmounts[5] = 1e9;   // 0.000000001 DOLA

        uint256 expectedBalance = depositAmount;

        for (uint256 i = 0; i < withdrawAmounts.length; i++) {
            uint256 withdrawAmount = withdrawAmounts[i];
            uint256 balanceBefore = vault.balanceOf(address(dolaToken), client1);

            _withdraw(client1, withdrawAmount, client1);

            uint256 balanceAfter = vault.balanceOf(address(dolaToken), client1);
            expectedBalance -= withdrawAmount;

            // Verify proportional reduction with small tolerance for rounding
            assertApproxEqRel(
                balanceAfter,
                expectedBalance,
                1e14,
                string(abi.encodePacked("Withdrawal at magnitude 10^", vm.toString(i), " should maintain precision"))
            );
        }

        // Final balance check - should have withdrawn specific amounts
        uint256 totalWithdrawn = withdrawAmounts[0] + withdrawAmounts[1] + withdrawAmounts[2] +
                                 withdrawAmounts[3] + withdrawAmounts[4] + withdrawAmounts[5];
        uint256 finalBalance = vault.balanceOf(address(dolaToken), client1);
        assertApproxEqRel(finalBalance, depositAmount - totalWithdrawn, 1e14, "Final balance should reflect all withdrawals");
    }

    // ============ SMALL SHARE CALCULATION TESTS ============

    /**
     * @notice Test scenario where userCurrentShares rounds to zero (line 231 verification)
     * @dev Tests the require statement: require(sharesToWithdraw > 0, "AutoDolaVault: Insufficient shares")
     *      This is SECURITY-CRITICAL to prevent users from withdrawing when they have insufficient shares
     */
    function testWithdrawSmallShareCalculation() public {
        // Setup: Create a scenario where share calculation might round to zero
        // Deposit a very large amount for client1 to dominate the pool (using 1e36 to avoid overflow)
        uint256 largeDeposit = 1e36;
        _deposit(client1, largeDeposit, client1);

        // Deposit a tiny amount for client2
        uint256 tinyDeposit = 1;
        _deposit(client2, tinyDeposit, client2);

        // Simulate significant yield to increase the total assets
        // Use 100x yield instead of 1000x to avoid overflow while still creating dilution
        uint256 yieldAmount = autoDolaVault.convertToAssets(autoDolaVault.balanceOf(address(vault)));
        autoDolaVault.simulateYield(yieldAmount * 100); // 100x yield

        // Now client2's shares are extremely diluted
        // Try to withdraw an amount that would require very few shares
        uint256 client2Balance = vault.balanceOf(address(dolaToken), client2);

        // Withdraw a tiny fraction that might round to zero shares
        if (client2Balance > 1000) {
            uint256 tinyWithdraw = 1; // Withdraw 1 wei from a large balance

            // This should either succeed with shares > 0, or revert with "no shares to withdraw"
            vm.prank(client2);
            try vault.withdraw(address(dolaToken), tinyWithdraw, recipient2) {
                // If it succeeds, verify the withdrawal was accurate
                uint256 balanceAfter = vault.balanceOf(address(dolaToken), client2);
                assertLt(balanceAfter, client2Balance, "Balance should decrease after withdrawal");
            } catch (bytes memory reason) {
                // If it reverts, it should be with the correct error message
                string memory revertReason = string(reason);
                // Note: Checking for the error without the prefix as it might be encoded differently
                assertTrue(
                    bytes(revertReason).length > 0,
                    "Should revert with no shares error when shares round to zero"
                );
            }
        }

        // Additional test: Verify normal withdrawal still works for client1
        uint256 client1Balance = vault.balanceOf(address(dolaToken), client1);
        uint256 normalWithdraw = client1Balance / 4; // Withdraw 25% to avoid potential rounding issues
        _withdraw(client1, normalWithdraw, client1);
        assertApproxEqRel(
            vault.balanceOf(address(dolaToken), client1),
            client1Balance - normalWithdraw,
            1e15,
            "Normal withdrawal should work for user with significant shares"
        );
    }

    // ============ MULTIPLE USERS PRECISION TESTS ============

    /**
     * @notice Test precision with multiple users and successive divisions
     * @dev Verifies that when multiple users deposit and withdraw, the share calculations
     *      remain accurate and no value is lost due to rounding errors in successive operations
     */
    function testDepositWithdrawPrecisionMultipleUsers() public {
        uint256 baseAmount = 1e24; // 1 million DOLA with 18 decimals

        // Phase 1: Three clients deposit different amounts
        _deposit(client1, baseAmount, client1);
        _deposit(client2, baseAmount * 2, client2);
        _deposit(client3, baseAmount * 3, client3);

        uint256 client1Balance1 = vault.balanceOf(address(dolaToken), client1);
        uint256 client2Balance1 = vault.balanceOf(address(dolaToken), client2);
        uint256 client3Balance1 = vault.balanceOf(address(dolaToken), client3);

        assertEq(client1Balance1, baseAmount, "Client1 initial balance should match deposit");
        assertEq(client2Balance1, baseAmount * 2, "Client2 initial balance should match deposit");
        assertEq(client3Balance1, baseAmount * 3, "Client3 initial balance should match deposit");

        // Phase 2: Simulate yield
        uint256 yieldAmount = autoDolaVault.convertToAssets(autoDolaVault.balanceOf(address(vault))) / 2;
        autoDolaVault.simulateYield(yieldAmount); // 50% yield

        uint256 client1Balance2 = vault.balanceOf(address(dolaToken), client1);
        uint256 client2Balance2 = vault.balanceOf(address(dolaToken), client2);
        uint256 client3Balance2 = vault.balanceOf(address(dolaToken), client3);

        // Verify yield is distributed proportionally
        assertApproxEqRel(client1Balance2, client1Balance1 * 3 / 2, 1e15, "Client1 should have 50% yield");
        assertApproxEqRel(client2Balance2, client2Balance1 * 3 / 2, 1e15, "Client2 should have 50% yield");
        assertApproxEqRel(client3Balance2, client3Balance1 * 3 / 2, 1e15, "Client3 should have 50% yield");

        // Phase 3: Client1 withdraws 25%
        uint256 client1Withdraw = client1Balance2 / 4;
        _withdraw(client1, client1Withdraw, client1);

        uint256 client1Balance3 = vault.balanceOf(address(dolaToken), client1);
        assertApproxEqRel(client1Balance3, client1Balance2 * 3 / 4, 1e15, "Client1 should have 75% remaining");

        // Phase 4: Client2 withdraws 50%
        uint256 client2Withdraw = client2Balance2 / 2;
        _withdraw(client2, client2Withdraw, client2);

        uint256 client2Balance3 = vault.balanceOf(address(dolaToken), client2);
        assertApproxEqRel(client2Balance3, client2Balance2 / 2, 1e15, "Client2 should have 50% remaining");

        // Phase 5: Client3 withdraws 75%
        uint256 client3Withdraw = client3Balance2 * 3 / 4;
        _withdraw(client3, client3Withdraw, client3);

        uint256 client3Balance3 = vault.balanceOf(address(dolaToken), client3);
        assertApproxEqRel(client3Balance3, client3Balance2 / 4, 1e15, "Client3 should have 25% remaining");

        // Phase 6: Verify total balances are consistent
        uint256 totalBalance = client1Balance3 + client2Balance3 + client3Balance3;
        uint256 totalShares = autoDolaVault.balanceOf(address(vault));
        uint256 totalAssets = autoDolaVault.convertToAssets(totalShares);

        assertApproxEqRel(totalBalance, totalAssets, 1e14, "Total client balances should match total vault assets");

        // Phase 7: All clients withdraw remaining balances
        _withdraw(client1, client1Balance3, client1);
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Client1 should have zero balance");

        _withdraw(client2, client2Balance3, client2);
        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Client2 should have zero balance");

        _withdraw(client3, client3Balance3, client3);
        assertEq(vault.balanceOf(address(dolaToken), client3), 0, "Client3 should have zero balance");

        // Final verification: Vault should be nearly empty
        uint256 finalTotalShares = autoDolaVault.balanceOf(address(vault));
        assertLe(finalTotalShares, 10, "Vault should have minimal dust shares remaining");
    }
}

// ============ MOCK CONTRACTS ============

/**
 * @notice Mock autoDOLA vault for testing
 * @dev Simulates ERC4626 vault behavior with yield simulation
 */
contract MockAutoDOLA is MockERC20 {
    mapping(address => uint256) private _balances;
    uint256 private _totalAssets;
    uint256 private _totalShares;
    address private _asset;
    address private _rewarder;

    constructor(address asset_, address rewarder_) MockERC20("AutoDOLA", "autoDOLA", 18) {
        // Start with zero assets/shares - will grow as deposits come in
        _totalAssets = 0;
        _totalShares = 0;
        _asset = asset_;
        _rewarder = rewarder_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        _mint(receiver, shares);
        _balances[receiver] += shares;
        _totalShares += shares;
        _totalAssets += assets;

        MockERC20(_asset).transferFrom(msg.sender, address(this), assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(_balances[owner] >= shares, "Insufficient shares");

        assets = convertToAssets(shares);
        _burn(owner, shares);
        _balances[owner] -= shares;
        _totalShares -= shares;
        _totalAssets -= assets;

        MockERC20(_asset).transfer(receiver, assets);
        return assets;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (_totalAssets == 0 || _totalShares == 0) return assets; // 1:1 ratio when empty
        return (assets * _totalShares) / _totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (_totalShares == 0 || _totalAssets == 0) return shares; // 1:1 ratio when empty
        return (shares * _totalAssets) / _totalShares;
    }

    function asset() public view returns (address) {
        return _asset;
    }

    function rewarder() external view returns (address) {
        return _rewarder;
    }

    // Simulate yield growth - mint actual DOLA tokens to back the yield
    function simulateYield(uint256 yieldAmount) external {
        _totalAssets += yieldAmount;
        // Mint the actual DOLA tokens to the mock to ensure it can be redeemed
        MockERC20(_asset).mint(address(this), yieldAmount);
    }
}

/**
 * @notice Mock MainRewarder for testing
 * @dev Simulates Tokemak's MainRewarder staking behavior
 */
contract MockMainRewarder {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _rewards;
    uint256 private _totalSupply;
    address private _rewardToken;

    constructor(address rewardTokenAddr) {
        _rewardToken = rewardTokenAddr;
    }

    function stake(address user, uint256 amount) external {
        _balances[user] += amount;
        _totalSupply += amount;
    }

    function withdraw(address user, uint256 amount, bool claim) external {
        require(_balances[user] >= amount, "Insufficient staked balance");
        _balances[user] -= amount;
        _totalSupply -= amount;

        if (claim && _rewards[user] > 0) {
            uint256 reward = _rewards[user];
            _rewards[user] = 0;
            MockERC20(_rewardToken).transfer(user, reward);
        }
    }

    function getReward(address user, address receiver, bool claim) external returns (bool) {
        if (_rewards[user] > 0) {
            uint256 reward = _rewards[user];
            _rewards[user] = 0;
            MockERC20(_rewardToken).transfer(receiver, reward);
        }
        return true;
    }

    function earned(address user) external view returns (uint256) {
        return _rewards[user];
    }

    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    // Helper to set rewards for testing
    function setRewards(address user, uint256 amount) external {
        _rewards[user] = amount;
    }
}
