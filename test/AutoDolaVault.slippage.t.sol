// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteVaults/AutoDolaYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title AutoDolaVaultSlippage
 * @notice Comprehensive tests for slippage protection and negative yield scenarios
 * @dev Tests critical security features that prevent loss of user funds in adverse market conditions
 */
contract AutoDolaVaultSlippage is Test {
    AutoDolaYieldStrategy public vault;
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

    // ============ SLIPPAGE PROTECTION TESTS ============

    /**
     * @notice Test slippage protection activates when redemption is less than expected (line 243)
     * @dev Validates: require(assetsReceived >= amount, "AutoDolaYieldStrategy: insufficient assets received")
     *      This is SECURITY-CRITICAL to prevent users from losing funds when autoDOLA redemption
     *      returns less than the requested withdrawal amount
     *
     *      NOTE: Line 243 protection is tested indirectly through the MockAutoDOLA redeem function.
     *      In real scenarios, this would catch cases where the autoDOLA vault's redemption
     *      returns fewer assets than expected due to slippage or market conditions.
     */
    function testWithdrawSlippageProtectionActivates() public {
        // Setup: Deposit funds for client1 and client2
        uint256 depositAmount = 1000e18;
        _deposit(client1, depositAmount, client1);
        _deposit(client2, depositAmount, client2);

        // Verify initial state
        uint256 initialBalance = vault.balanceOf(address(dolaToken), client1);
        assertEq(initialBalance, depositAmount, "Initial balance should match deposit");

        // Simulate negative yield scenario - autoDOLA loses 20% of value
        // This creates a situation where redemption returns less than expected
        uint256 totalAssets = autoDolaVault.convertToAssets(autoDolaVault.balanceOf(address(vault)));
        autoDolaVault.simulateNegativeYield(totalAssets / 5); // 20% loss

        // Calculate new balance after loss
        uint256 balanceAfterLoss = vault.balanceOf(address(dolaToken), client1);
        assertLt(balanceAfterLoss, depositAmount, "Balance should reflect the loss");
        assertApproxEqRel(balanceAfterLoss, 800e18, 1e15, "Balance should be ~80% of original");

        // CRITICAL TEST: Test line 243 slippage protection
        // Enable slippage to simulate autoDOLA vault returning less than expected
        // This tests the specific protection: require(assetsReceived >= amount, "AutoDolaYieldStrategy: insufficient assets received")
        autoDolaVault.enableSlippage(10); // 10% slippage

        // Try to withdraw balanceAfterLoss (~800e18)
        // Due to 10% slippage, autoDOLA will only return ~720e18 (90% of 800e18)
        // This triggers line 243 protection because assetsReceived (720e18) < amount (800e18)
        vm.prank(client1);
        vm.expectRevert("AutoDolaYieldStrategy: insufficient assets received");
        vault.withdraw(address(dolaToken), balanceAfterLoss, client1);

        // Disable slippage for subsequent operations
        // (Note: expectRevert rolls back state, so slippage is still enabled)
        autoDolaVault.disableSlippage();

        // Now withdraw should work normally without slippage
        uint256 safeWithdrawAmount = balanceAfterLoss;
        _withdraw(client1, safeWithdrawAmount, client1);

        // After successful withdrawal, balance should be near zero
        assertLe(vault.balanceOf(address(dolaToken), client1), 1e15, "Balance should be nearly zero after successful withdrawal");
        assertApproxEqRel(dolaToken.balanceOf(client1), safeWithdrawAmount, 1e14, "Recipient should receive the safe amount");

        // Additional verification: The line 243 check prevents scenarios where
        // the autoDOLA vault would return less than requested
        // Our MockAutoDOLA honors the conversion correctly, so this protection ensures
        // that in production, any discrepancy would be caught and reverted
        uint256 client2Balance = vault.balanceOf(address(dolaToken), client2);
        _withdraw(client2, client2Balance, client2);
        assertApproxEqRel(dolaToken.balanceOf(client2), client2Balance, 1e14, "Client2 should receive expected amount");
    }

    // ============ NEGATIVE YIELD TESTS ============

    /**
     * @notice Test system behavior when autoDOLA loses value (negative yield scenario)
     * @dev Ensures the vault correctly reflects losses and prevents users from withdrawing
     *      more than the actual value of their shares
     */
    function testNegativeYieldScenario() public {
        // Setup: Multiple clients deposit
        _deposit(client1, 1000e18, client1);
        _deposit(client2, 2000e18, client2);
        _deposit(client3, 3000e18, client3);

        // Verify initial balances
        assertEq(vault.balanceOf(address(dolaToken), client1), 1000e18, "Client1 initial balance");
        assertEq(vault.balanceOf(address(dolaToken), client2), 2000e18, "Client2 initial balance");
        assertEq(vault.balanceOf(address(dolaToken), client3), 3000e18, "Client3 initial balance");

        // Scenario 1: 30% negative yield
        {
            uint256 totalAssets = autoDolaVault.convertToAssets(autoDolaVault.balanceOf(address(vault)));
            autoDolaVault.simulateNegativeYield((totalAssets * 30) / 100);
        }

        // Verify balances reflect the proportional loss
        assertApproxEqRel(vault.balanceOf(address(dolaToken), client1), 700e18, 1e15, "Client1 should have ~70% remaining");
        assertApproxEqRel(vault.balanceOf(address(dolaToken), client2), 1400e18, 1e15, "Client2 should have ~70% remaining");
        assertApproxEqRel(vault.balanceOf(address(dolaToken), client3), 2100e18, 1e15, "Client3 should have ~70% remaining");

        // Scenario 2: Verify withdrawals work with reduced balances
        {
            uint256 client1Balance = vault.balanceOf(address(dolaToken), client1);
            _withdraw(client1, client1Balance / 2, client1);
            assertApproxEqRel(
                vault.balanceOf(address(dolaToken), client1),
                client1Balance / 2,
                1e15,
                "Client1 balance should reduce correctly after withdrawal"
            );
        }

        // Scenario 3: Further negative yield (additional 20% loss on remaining)
        {
            uint256 totalAssets = autoDolaVault.convertToAssets(autoDolaVault.balanceOf(address(vault)));
            autoDolaVault.simulateNegativeYield((totalAssets * 20) / 100);
        }

        // Verify losses compound correctly - Expected: 70% of original * 80% = 56% of original
        assertApproxEqRel(
            vault.balanceOf(address(dolaToken), client2),
            1120e18, // 2000 * 0.56
            1e14,
            "Client2 should have ~56% after compounding losses"
        );

        // Scenario 4: Verify all clients can still withdraw their remaining balances
        _withdraw(client1, vault.balanceOf(address(dolaToken), client1), client1);
        _withdraw(client2, vault.balanceOf(address(dolaToken), client2), client2);
        _withdraw(client3, vault.balanceOf(address(dolaToken), client3), client3);

        // Verify all balances are near zero
        assertLe(vault.balanceOf(address(dolaToken), client1), 1e15, "Client1 should have near-zero balance");
        assertLe(vault.balanceOf(address(dolaToken), client2), 1e15, "Client2 should have near-zero balance");
        assertLe(vault.balanceOf(address(dolaToken), client3), 1e15, "Client3 should have near-zero balance");

        // Verify total withdrawn matches remaining value (losses are reflected)
        uint256 totalWithdrawn = dolaToken.balanceOf(client1) +
                                 dolaToken.balanceOf(client2) +
                                 dolaToken.balanceOf(client3);

        // Total withdrawn should be significantly less than deposited due to losses
        assertLt(totalWithdrawn, 6000e18, "Total withdrawn should be less than deposited due to losses");

        // But should match the expected value after all losses
        // Note: Due to client1's early withdrawal and rounding, the actual amount varies slightly
        // The calculation is complex due to sequential operations and yield compounding
        // Approximately 57.17% of the total deposited amount remains after all losses
        assertApproxEqRel(totalWithdrawn, 3430e18, 2e13, "Total withdrawn should match expected remaining value");
    }

    // ============ ZERO SHARES PROTECTION TEST ============

    /**
     * @notice Test withdrawal protection when shares calculation rounds to zero (line 231)
     * @dev Validates: require(sharesToWithdraw > 0, "AutoDolaYieldStrategy: no shares to withdraw")
     *      This prevents users from attempting withdrawals that would result in zero shares
     *
     *      Line 230 calculation: sharesToWithdraw = (userCurrentShares * amount) / currentBalance
     *      When amount is very small relative to currentBalance, this can round to zero
     */
    function testWithdrawWhenSharesRoundToZero() public {
        // Setup: Create scenario where share calculation rounds to zero
        // Client1 deposits a large amount
        uint256 largeDeposit = 1e30; // Use 1e30 instead of 1e36 to avoid potential overflow
        _deposit(client1, largeDeposit, client1);

        // Client2 deposits a smaller but significant amount
        uint256 client2Deposit = 1e24;
        _deposit(client2, client2Deposit, client2);

        // Simulate massive yield to increase the pool significantly
        // This increases the value per share, making tiny withdrawals round to zero shares
        uint256 totalAssets = autoDolaVault.convertToAssets(autoDolaVault.balanceOf(address(vault)));
        autoDolaVault.simulateYield(totalAssets * 100); // 100x yield

        // Now client2's balance has increased due to yield
        uint256 client2Balance = vault.balanceOf(address(dolaToken), client2);
        assertGt(client2Balance, client2Deposit, "Balance should have increased due to yield");

        // Try to withdraw an extremely small amount (1 wei)
        // Due to the formula: sharesToWithdraw = (userCurrentShares * amount) / currentBalance
        // With amount = 1 and currentBalance being very large (due to yield), this rounds to 0
        uint256 tinyWithdraw = 1; // 1 wei

        // This should revert with "no shares to withdraw" error
        vm.prank(client2);
        vm.expectRevert("AutoDolaYieldStrategy: no shares to withdraw");
        vault.withdraw(address(dolaToken), tinyWithdraw, client2);

        // Verify client2's balance is unchanged
        uint256 balanceAfterFailedWithdraw = vault.balanceOf(address(dolaToken), client2);
        assertEq(balanceAfterFailedWithdraw, client2Balance, "Balance should be unchanged after failed withdrawal");

        // Verify that a larger withdrawal that results in non-zero shares works
        // Withdraw a more substantial amount (1% of balance)
        uint256 largerWithdraw = client2Balance / 100;
        if (largerWithdraw > 1000) { // Ensure it's large enough to not round to zero
            _withdraw(client2, largerWithdraw, client2);

            // Should succeed and reduce balance appropriately
            assertApproxEqRel(
                vault.balanceOf(address(dolaToken), client2),
                client2Balance - largerWithdraw,
                1e15,
                "Balance should reduce correctly after successful withdrawal"
            );
        }

        // Verify the full balance can still be withdrawn
        uint256 remainingBalance = vault.balanceOf(address(dolaToken), client2);
        _withdraw(client2, remainingBalance, client2);
        assertLe(vault.balanceOf(address(dolaToken), client2), 1e15, "Balance should be near zero after full withdrawal");
    }
}

// ============ MOCK CONTRACTS ============

/**
 * @notice Mock autoDOLA vault for testing with negative yield support
 * @dev Simulates ERC4626 vault behavior with both positive and negative yield
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

        // Apply slippage if enabled (simulates market conditions where redemption < expected)
        uint256 actualAssets = assets;
        if (_slippageEnabled) {
            actualAssets = assets - (assets * _slippagePercent / 100);
            // Disable slippage after one use (one-time trigger)
            _slippageEnabled = false;
        }

        _burn(owner, shares);
        _balances[owner] -= shares;
        _totalShares -= shares;
        _totalAssets -= actualAssets; // Use actual assets transferred

        MockERC20(_asset).transfer(receiver, actualAssets);
        return actualAssets;
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

    // Simulate positive yield growth - mint actual DOLA tokens to back the yield
    function simulateYield(uint256 yieldAmount) external {
        _totalAssets += yieldAmount;
        // Mint the actual DOLA tokens to the mock to ensure it can be redeemed
        MockERC20(_asset).mint(address(this), yieldAmount);
    }

    // Simulate negative yield - reduce total assets and burn corresponding DOLA tokens
    function simulateNegativeYield(uint256 lossAmount) external {
        require(_totalAssets >= lossAmount, "Loss exceeds total assets");
        _totalAssets -= lossAmount;
        // Burn the actual DOLA tokens to reflect the loss
        MockERC20(_asset).burn(address(this), lossAmount);
    }

    // Simulate slippage - force the next redeem to return less assets than calculated
    bool private _slippageEnabled;
    uint256 private _slippagePercent; // Percentage to reduce (e.g., 10 = 10% slippage)

    function enableSlippage(uint256 slippagePercent) external {
        _slippageEnabled = true;
        _slippagePercent = slippagePercent;
    }

    function disableSlippage() external {
        _slippageEnabled = false;
        _slippagePercent = 0;
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
