// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title AutoDolaWithdrawalDiscrepancy
 * @notice RED PHASE TEST - Demonstrates withdrawal amount discrepancy bug
 * @dev This test demonstrates the bug on line 251 of AutoDolaYieldStrategy.sol
 *      where the contract transfers `amount` instead of `assetsReceived` to the user.
 *
 *      THE BUG:
 *      Line 238: uint256 assetsReceived = autoDolaVault.redeem(sharesToWithdraw, address(this), address(this));
 *      Line 251: dolaToken.safeTransfer(recipient, amount);  // BUG: Should be assetsReceived
 *
 *      EXPECTED BEHAVIOR: User should receive assetsReceived (actual amount from vault)
 *      ACTUAL BEHAVIOR: User receives amount (requested amount)
 *
 *      This test MUST FAIL with current implementation to demonstrate the bug.
 *      It will pass once the fix is implemented in story 015.2.
 */
contract AutoDolaWithdrawalDiscrepancy is Test {
    AutoDolaYieldStrategy public vault;
    MockERC20 public dolaToken;
    MockERC20 public tokeToken;
    MockAutoDOLAWithRounding public autoDolaVault;
    MockMainRewarder public mainRewarder;

    address public owner = address(1);
    address public client1 = address(2);
    address public recipient1 = address(5);

    // Events from AutoDolaYieldStrategy
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

        // Deploy mock autoDOLA vault with rounding capability
        autoDolaVault = new MockAutoDOLAWithRounding(address(dolaToken), address(mainRewarder));

        // Deploy AutoDolaYieldStrategy
        vault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Authorize client
        vm.startPrank(owner);
        vault.setClient(client1, true);
        vm.stopPrank();
    }

    // ============ HELPER FUNCTIONS ============

    function _deposit(address client, uint256 amount, address recipient) internal {
        dolaToken.mint(client, amount);
        vm.startPrank(client);
        dolaToken.approve(address(vault), amount);
        vault.deposit(address(dolaToken), amount, recipient);
        vm.stopPrank();
    }

    function _withdraw(address client, uint256 amount, address recipient) internal {
        vm.prank(client);
        vault.withdraw(address(dolaToken), amount, recipient);
    }

    // ============ BUG DEMONSTRATION TESTS ============

    /**
     * @notice RED PHASE TEST - Demonstrates withdrawal discrepancy due to rounding
     * @dev This test creates a scenario where vault rounding causes assetsReceived != amount
     *
     * SCENARIO:
     * 1. User deposits 1000 DOLA
     * 2. Another user deposits to create rounding conditions
     * 3. User withdraws an amount that causes rounding in share conversion
     * 4. Vault returns slightly less than requested due to rounding
     * 5. BUG: Contract tries to transfer requested amount instead of actual received
     *
     * EXPECTED FAILURE:
     * - Contract should transfer assetsReceived (e.g., 299 DOLA)
     * - But it transfers amount (300 DOLA)
     * - This causes revert: "ERC20: transfer amount exceeds balance"
     * - Or accounting errors if contract happens to have extra balance
     */
    function testWithdrawalAmountDiscrepancy_RoundingDown() public {
        console.log("\n=== RED PHASE: Withdrawal Discrepancy - Rounding Down ===");

        // Step 1: Initial deposit by recipient1
        uint256 initialDeposit = 1000 ether;
        _deposit(client1, initialDeposit, recipient1);
        console.log("Initial deposit:", initialDeposit);

        // Step 2: Create rounding conditions by having vault in non-1:1 ratio
        // Add extra DOLA to vault to change the exchange rate
        uint256 yieldAmount = 33 ether; // Prime number to cause interesting rounding
        autoDolaVault.simulateYield(yieldAmount);
        console.log("Yield added to vault:", yieldAmount);

        // Step 3: Get recipient1's balance after yield
        uint256 balanceWithYield = vault.balanceOf(address(dolaToken), recipient1);
        console.log("Recipient balance with yield:", balanceWithYield);

        // Step 4: Attempt withdrawal that will cause rounding
        // We'll withdraw a specific amount that causes share rounding
        uint256 withdrawAmount = 300 ether;
        console.log("Requested withdrawal amount:", withdrawAmount);

        // Step 5: Calculate what the vault will actually return
        uint256 totalShares = mainRewarder.balanceOf(address(vault));
        uint256 userStoredBalance = initialDeposit; // clientBalances[token][recipient]
        uint256 userCurrentShares = (totalShares * userStoredBalance) / initialDeposit;
        uint256 sharesToWithdraw = (userCurrentShares * withdrawAmount) / balanceWithYield;

        console.log("Shares to withdraw:", sharesToWithdraw);

        // What the vault will actually return (with rounding)
        uint256 expectedAssetsReceived = autoDolaVault.convertToAssets(sharesToWithdraw);
        console.log("Expected assets from vault:", expectedAssetsReceived);
        console.log("Discrepancy (amount - assetsReceived):", withdrawAmount - expectedAssetsReceived);

        // Verify we have a discrepancy condition
        if (withdrawAmount == expectedAssetsReceived) {
            console.log("WARNING: No discrepancy created, adjusting test parameters");
            // This indicates test needs parameter adjustment
            assertTrue(false, "Test setup failed: no discrepancy created");
        }

        // Step 6: Get recipient's DOLA balance before withdrawal
        uint256 recipientBalanceBefore = dolaToken.balanceOf(recipient1);
        console.log("Recipient DOLA balance before:", recipientBalanceBefore);

        // Step 7: Attempt withdrawal - THIS SHOULD FAIL with current buggy implementation
        // The bug causes the contract to try transferring `amount` instead of `assetsReceived`
        // Since contract only receives `assetsReceived` from vault, transfer will fail

        console.log("\n--- Attempting withdrawal ---");
        console.log("EXPECTED BEHAVIOR: User should receive", expectedAssetsReceived, "wei (actual from vault)");
        console.log("BUGGY BEHAVIOR: Contract will try to transfer", withdrawAmount, "wei (requested amount)");
        console.log("DISCREPANCY:", withdrawAmount - expectedAssetsReceived, "wei");

        // Get recipient's DOLA balance before withdrawal
        uint256 recipientBalanceBefore2 = dolaToken.balanceOf(recipient1);

        // RED PHASE: This test MUST FAIL with current buggy implementation
        // The bug on line 251 causes withdrawal to revert because contract
        // tries to transfer `amount` (300 DOLA) but only has `assetsReceived` (299.999... DOLA)

        // Perform the withdrawal - with the bug, this will revert
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, recipient1);

        // ASSERTION: User should receive the ACTUAL amount from vault, not the requested amount
        uint256 recipientBalanceAfter = dolaToken.balanceOf(recipient1);
        uint256 actualReceived = recipientBalanceAfter - recipientBalanceBefore2;

        console.log("\n--- Verifying correct behavior ---");
        console.log("User received:", actualReceived);
        console.log("Expected (assetsReceived):", expectedAssetsReceived);

        // THIS ASSERTION WILL FAIL because the withdrawal reverted
        // With the fix in story 015.2, withdrawal won't revert and user will receive assetsReceived
        assertEq(actualReceived, expectedAssetsReceived,
            "User should receive assetsReceived from vault, not requested amount");
    }

    /**
     * @notice RED PHASE TEST - Demonstrates withdrawal discrepancy after yield accrual
     * @dev This test shows the bug when exchange rate changes due to yield growth
     *
     * SCENARIO:
     * 1. User deposits 1000 DOLA
     * 2. Significant yield accrues (exchange rate changes)
     * 3. User withdraws partial amount
     * 4. Share-to-asset conversion creates discrepancy
     * 5. BUG: Contract transfers wrong amount
     *
     * EXPECTED FAILURE:
     * - Vault returns different amount than requested
     * - Contract tries to transfer requested amount
     * - Causes accounting error or revert
     */
    function testWithdrawalAmountDiscrepancy_YieldAccrual() public {
        console.log("\n=== RED PHASE: Withdrawal Discrepancy - Yield Accrual ===");

        // Step 1: Initial deposit
        uint256 initialDeposit = 5000 ether;
        _deposit(client1, initialDeposit, recipient1);
        console.log("Initial deposit:", initialDeposit);

        // Step 2: Yield accrual that creates non-integer exchange rate
        // Use prime number to ensure rounding
        uint256 yieldAmount = 137 ether; // Prime number for rounding
        autoDolaVault.simulateYield(yieldAmount);
        console.log("Yield accrued:", yieldAmount);

        // Step 3: Check balance with yield
        uint256 balanceWithYield = vault.balanceOf(address(dolaToken), recipient1);
        console.log("Balance with yield:", balanceWithYield);
        console.log("Expected balance:", initialDeposit + yieldAmount);

        // Step 4: Withdraw amount that causes conversion rounding
        // Choose amount that will cause rounding in share calculation
        uint256 withdrawAmount = 1234 ether; // Non-round number for rounding
        console.log("Withdrawal amount:", withdrawAmount);

        // Step 5: Calculate actual vault return
        uint256 totalShares = mainRewarder.balanceOf(address(vault));
        uint256 userStoredBalance = initialDeposit;
        uint256 userCurrentShares = (totalShares * userStoredBalance) / initialDeposit;
        uint256 sharesToWithdraw = (userCurrentShares * withdrawAmount) / balanceWithYield;
        uint256 expectedAssetsReceived = autoDolaVault.convertToAssets(sharesToWithdraw);

        console.log("Shares to withdraw:", sharesToWithdraw);
        console.log("Expected assets from vault:", expectedAssetsReceived);
        console.log("Discrepancy:", withdrawAmount > expectedAssetsReceived ?
                    withdrawAmount - expectedAssetsReceived :
                    expectedAssetsReceived - withdrawAmount);

        // Step 6: Perform withdrawal and verify correct behavior
        console.log("\n--- Attempting withdrawal ---");
        console.log("EXPECTED: User receives", expectedAssetsReceived, "wei (actual from vault)");
        console.log("BUGGY CODE: Will try to transfer", withdrawAmount, "wei (requested)");

        uint256 recipientBalanceBefore2 = dolaToken.balanceOf(recipient1);

        // RED PHASE: With bug, this reverts. After fix, it succeeds.
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, recipient1);

        uint256 recipientBalanceAfter = dolaToken.balanceOf(recipient1);
        uint256 actualReceived = recipientBalanceAfter - recipientBalanceBefore2;

        // Assert correct behavior: user should receive assetsReceived, not amount
        assertEq(actualReceived, expectedAssetsReceived,
            "User should receive actual vault output (assetsReceived), not requested amount");
    }

    /**
     * @notice RED PHASE TEST - Demonstrates discrepancy with dust amounts
     * @dev Shows bug when dealing with small amounts that cause precision loss
     *
     * SCENARIO:
     * 1. User deposits amount that creates fractional shares
     * 2. Withdraw amount that results in dust-level rounding
     * 3. Conversion creates tiny discrepancy
     * 4. BUG: Contract transfers wrong micro-amount
     */
    function testWithdrawalAmountDiscrepancy_DustRounding() public {
        console.log("\n=== RED PHASE: Withdrawal Discrepancy - Dust Rounding ===");

        // Step 1: Deposit amount with precision
        uint256 initialDeposit = 1234567890123456789; // 1.234... DOLA
        _deposit(client1, initialDeposit, recipient1);
        console.log("Initial deposit (wei):", initialDeposit);

        // Step 2: Add small yield to change ratio
        uint256 yieldAmount = 7 ether; // Small yield
        autoDolaVault.simulateYield(yieldAmount);
        console.log("Small yield added:", yieldAmount);

        // Step 3: Withdraw amount with precision that causes rounding
        uint256 withdrawAmount = 987654321098765432; // 0.987... DOLA
        console.log("Withdrawal amount (wei):", withdrawAmount);

        // Step 4: Calculate expected vault return
        uint256 balanceWithYield = vault.balanceOf(address(dolaToken), recipient1);
        uint256 totalShares = mainRewarder.balanceOf(address(vault));
        uint256 userStoredBalance = initialDeposit;
        uint256 userCurrentShares = (totalShares * userStoredBalance) / initialDeposit;
        uint256 sharesToWithdraw = (userCurrentShares * withdrawAmount) / balanceWithYield;
        uint256 expectedAssetsReceived = autoDolaVault.convertToAssets(sharesToWithdraw);

        console.log("Expected from vault:", expectedAssetsReceived);
        console.log("Dust discrepancy:", withdrawAmount > expectedAssetsReceived ?
                    withdrawAmount - expectedAssetsReceived :
                    expectedAssetsReceived - withdrawAmount);

        // Step 5: Perform withdrawal and verify correct behavior
        console.log("\n--- Attempting withdrawal ---");
        console.log("EXPECTED: User receives", expectedAssetsReceived, "wei");
        console.log("BUGGY: Will transfer", withdrawAmount, "wei");

        uint256 recipientBalanceBefore2 = dolaToken.balanceOf(recipient1);

        // RED PHASE: With bug, reverts. After fix, succeeds.
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, recipient1);

        uint256 recipientBalanceAfter = dolaToken.balanceOf(recipient1);
        uint256 actualReceived = recipientBalanceAfter - recipientBalanceBefore2;

        // Assert: user should receive assetsReceived
        assertEq(actualReceived, expectedAssetsReceived,
            "User should receive assetsReceived, not requested amount");
    }
}

/**
 * @notice Mock autoDOLA vault that simulates rounding in share conversions
 * @dev Explicitly designed to create amount != assetsReceived scenarios
 */
contract MockAutoDOLAWithRounding is MockERC20 {
    mapping(address => uint256) private _balances;
    uint256 private _totalAssets;
    uint256 private _totalShares;
    address private _asset;
    address private _rewarder;

    constructor(address asset_, address rewarder_) MockERC20("AutoDOLA", "autoDOLA", 18) {
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

        // This conversion can cause rounding - key to demonstrating the bug
        assets = convertToAssets(shares);

        _burn(owner, shares);
        _balances[owner] -= shares;
        _totalShares -= shares;
        _totalAssets -= assets;

        MockERC20(_asset).transfer(receiver, assets);
        return assets;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (_totalAssets == 0 || _totalShares == 0) return assets;
        // Rounding down division - can cause discrepancy
        return (assets * _totalShares) / _totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (_totalShares == 0 || _totalAssets == 0) return shares;
        // Rounding down division - can cause discrepancy
        return (shares * _totalAssets) / _totalShares;
    }

    function asset() public view returns (address) {
        return _asset;
    }

    function rewarder() external view returns (address) {
        return _rewarder;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalShares;
    }

    // Simulate yield growth
    function simulateYield(uint256 yieldAmount) external {
        _totalAssets += yieldAmount;
        MockERC20(_asset).mint(address(this), yieldAmount);
    }
}

/**
 * @notice Mock MainRewarder for testing
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

    function setRewards(address user, uint256 amount) external {
        _rewards[user] = amount;
    }
}
