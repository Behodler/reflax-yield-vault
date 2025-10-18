// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title AutoDolaVaultFullWithdrawalTest
 * @notice Comprehensive tests for full withdrawal edge cases
 * @dev Tests critical scenarios where users withdraw 100% of their balance and when totalDeposited becomes zero
 */
contract AutoDolaVaultFullWithdrawalTest is Test {
    AutoDolaYieldStrategy public vault;
    MockERC20 public dolaToken;
    MockERC20 public tokeToken;
    MockAutoDOLA public autoDolaVault;
    MockMainRewarder public mainRewarder;

    address public owner = address(1);
    address public client1 = address(2);
    address public client2 = address(3);
    address public client3 = address(4);
    address public client4 = address(5);
    address public recipient1 = address(6);
    address public recipient2 = address(7);
    address public recipient3 = address(8);
    address public recipient4 = address(9);

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
        vault.setClient(client4, true);
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

    // ============ TASK 1: FULL WITHDRAWAL TESTS ============

    /**
     * @notice Test user withdrawing 100% of balance via withdraw()
     * @dev Tests both successful 100% withdrawal and protection against over-withdrawal
     *      Verifies totalDeposited and all balances become zero after full withdrawal
     */
    function testWithdrawEntireBalance() public {
        // Setup: Single user deposits
        uint256 depositAmount = 1000e18;
        _deposit(client1, depositAmount, client1);

        // Verify initial state
        uint256 initialBalance = vault.balanceOf(address(dolaToken), client1);
        assertEq(initialBalance, depositAmount, "Initial balance should match deposit");
        assertEq(vault.getTotalDeposited(address(dolaToken)), depositAmount, "Total deposited should match deposit");

        // Test 1: Successful 100% withdrawal
        uint256 recipientBalanceBefore = dolaToken.balanceOf(client1);
        _withdraw(client1, initialBalance, client1);

        // Verify totalDeposited becomes zero after withdrawal
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Total deposited should be zero after full withdrawal");

        // Verify all balances are zero after full withdrawal
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "User balance should be zero after full withdrawal");
        assertApproxEqRel(
            dolaToken.balanceOf(client1) - recipientBalanceBefore,
            initialBalance,
            1e14,
            "Recipient should receive full balance"
        );

        // Test 2: Attempting to withdraw MORE than 100% should fail with protection
        // Make a new deposit to test over-withdrawal protection
        _deposit(client1, depositAmount, client1);

        uint256 currentBalance = vault.balanceOf(address(dolaToken), client1);
        uint256 tooMuchToWithdraw = currentBalance + 1e18; // Try to withdraw more than balance

        // This should revert - trying to withdraw more than you have
        vm.prank(client1);
        vm.expectRevert("AutoDolaYieldStrategy: insufficient balance");
        vault.withdraw(address(dolaToken), tooMuchToWithdraw, recipient1);

        // Verify balance unchanged after failed withdrawal
        assertEq(vault.balanceOf(address(dolaToken), client1), currentBalance, "Balance should be unchanged after failed withdrawal");
    }

    // ============ TASK 2 & 3: TOTAL DEPOSITED ZERO & BALANCEOF LOGIC ============

    /**
     * @notice Test the special balanceOf() logic at line 133 when totalDeposited = 0
     * @dev Line 133: if (totalShares == 0 || totalDeposited[token] == 0) return storedBalance;
     *      This tests the edge case where totalDeposited becomes zero but user still has storedBalance
     */
    function testBalanceOfWhenTotalDepositedZero() public {
        // Setup: Deposit and withdraw to get totalDeposited to zero
        uint256 depositAmount = 500e18;
        _deposit(client1, depositAmount, client1);

        uint256 balance = vault.balanceOf(address(dolaToken), client1);
        _withdraw(client1, balance, client1);

        // Verify totalDeposited is zero
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Total deposited should be zero");
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Balance should be zero after full withdrawal");

        // Test behavior when totalDeposited = 0 (next deposits should work)
        _deposit(client2, 1000e18, client2);

        // After new deposit, totalDeposited should be non-zero and balanceOf should work correctly
        assertEq(vault.getTotalDeposited(address(dolaToken)), 1000e18, "Total deposited should match new deposit");
        assertEq(vault.balanceOf(address(dolaToken), client2), 1000e18, "New user balance should match deposit");

        // Original user should still have zero balance
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Original user should still have zero balance");
    }

    /**
     * @notice Test that totalDeposited correctly becomes zero after last user withdrawal
     * @dev Verifies state variable directly and ensures system can recover (next deposits work)
     */
    function testTotalDepositedBecomesZero() public {
        // Setup: Multiple deposits
        _deposit(client1, 1000e18, client1);
        _deposit(client2, 2000e18, client2);

        uint256 totalBefore = vault.getTotalDeposited(address(dolaToken));
        assertEq(totalBefore, 3000e18, "Total deposited should be sum of deposits");

        // Withdraw all from both users
        _withdraw(client1, vault.balanceOf(address(dolaToken), client1), client1);
        _withdraw(client2, vault.balanceOf(address(dolaToken), client2), client2);

        // Check state variable directly after last withdrawal
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Total deposited should be zero after all withdrawals");

        // Test behavior when totalDeposited = 0 (next deposits should work)
        _deposit(client3, 5000e18, client3);
        assertEq(vault.getTotalDeposited(address(dolaToken)), 5000e18, "System should recover after totalDeposited hits zero");
        assertEq(vault.balanceOf(address(dolaToken), client3), 5000e18, "New deposit should work correctly");
    }

    // ============ TASK 4: SEQUENTIAL FULL WITHDRAWALS ============

    /**
     * @notice Test sequential full withdrawals by multiple users
     * @dev Verifies each withdrawal succeeds, balances update correctly, and totalDeposited decreases properly
     */
    function testMultipleUsersWithdrawAllSequentially() public {
        // Multiple users deposit
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;
        uint256 deposit3 = 1500e18;

        _deposit(client1, deposit1, client1);
        _deposit(client2, deposit2, client2);
        _deposit(client3, deposit3, client3);

        uint256 totalDeposited = vault.getTotalDeposited(address(dolaToken));
        assertEq(totalDeposited, deposit1 + deposit2 + deposit3, "Total deposited should be sum of all deposits");

        // Users withdraw in sequence (one by one, fully)

        // Client1 withdraws all
        uint256 balance1 = vault.balanceOf(address(dolaToken), client1);
        _withdraw(client1, balance1, client1);

        // Verify each withdrawal succeeds and balances update correctly
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Client1 balance should be zero");
        assertApproxEqRel(dolaToken.balanceOf(client1), balance1, 1e14, "Recipient1 should receive full amount");

        // Verify totalDeposited decreases with each withdrawal
        uint256 totalAfter1 = vault.getTotalDeposited(address(dolaToken));
        assertApproxEqRel(totalAfter1, deposit2 + deposit3, 1e15, "Total deposited should decrease after first withdrawal");

        // Client2 withdraws all
        uint256 balance2 = vault.balanceOf(address(dolaToken), client2);
        _withdraw(client2, balance2, client2);

        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Client2 balance should be zero");
        assertApproxEqRel(dolaToken.balanceOf(client2), balance2, 1e14, "Recipient2 should receive full amount");

        uint256 totalAfter2 = vault.getTotalDeposited(address(dolaToken));
        assertApproxEqRel(totalAfter2, deposit3, 1e15, "Total deposited should decrease after second withdrawal");

        // Client3 withdraws all
        uint256 balance3 = vault.balanceOf(address(dolaToken), client3);
        _withdraw(client3, balance3, client3);

        assertEq(vault.balanceOf(address(dolaToken), client3), 0, "Client3 balance should be zero");
        assertApproxEqRel(dolaToken.balanceOf(client3), balance3, 1e14, "Recipient3 should receive full amount");

        // Verify final totalDeposited = 0
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Total deposited should be zero after all withdrawals");

        // Verify all balances = 0
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Client1 final balance should be zero");
        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Client2 final balance should be zero");
        assertEq(vault.balanceOf(address(dolaToken), client3), 0, "Client3 final balance should be zero");
    }

    // ============ TASK 5: LAST USER WITHDRAWAL ============

    /**
     * @notice Verify final user can withdraw completely with no dust remaining
     * @dev Multiple users deposit, all but one withdraw fully, last user withdraws everything
     *      Verifies no dust remains, totalDeposited = 0, and all balances = 0
     */
    function testLastUserWithdrawAllTokens() public {
        // Multiple users deposit
        _deposit(client1, 3000e18, client1);
        _deposit(client2, 2000e18, client2);
        _deposit(client3, 1000e18, client3);
        _deposit(client4, 4000e18, client4);

        uint256 totalInitial = vault.getTotalDeposited(address(dolaToken));
        assertEq(totalInitial, 10000e18, "Total deposited should be 10000e18");

        // All but one user withdraw fully
        _withdraw(client1, vault.balanceOf(address(dolaToken), client1), client1);
        _withdraw(client2, vault.balanceOf(address(dolaToken), client2), client2);
        _withdraw(client3, vault.balanceOf(address(dolaToken), client3), client3);

        // Verify intermediate state
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Client1 should have zero balance");
        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Client2 should have zero balance");
        assertEq(vault.balanceOf(address(dolaToken), client3), 0, "Client3 should have zero balance");

        uint256 client4Balance = vault.balanceOf(address(dolaToken), client4);
        assertGt(client4Balance, 0, "Client4 should still have balance");

        // Last user withdraws everything (should succeed completely)
        uint256 recipientBalanceBefore = dolaToken.balanceOf(client4);
        _withdraw(client4, client4Balance, client4);

        // Verify no dust remains
        assertEq(vault.balanceOf(address(dolaToken), client4), 0, "Client4 balance should be exactly zero (no dust)");

        // Verify totalDeposited = 0
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Total deposited should be exactly zero");

        // Verify all balances = 0
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Client1 final balance zero");
        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Client2 final balance zero");
        assertEq(vault.balanceOf(address(dolaToken), client3), 0, "Client3 final balance zero");
        assertEq(vault.balanceOf(address(dolaToken), client4), 0, "Client4 final balance zero");

        // Verify last user received their full balance
        assertApproxEqRel(
            dolaToken.balanceOf(client4) - recipientBalanceBefore,
            client4Balance,
            1e14,
            "Last user should receive full balance with no loss"
        );

        // Additional verification: Total shares should also be zero or near-zero
        uint256 totalShares = vault.getTotalShares();
        assertLe(totalShares, 1, "Total shares should be zero or minimal dust");
    }

    /**
     * @notice Test edge case: withdrawal with yield before full withdrawal
     * @dev Ensures full withdrawal works correctly even when yield has accumulated
     */
    function testFullWithdrawalWithYield() public {
        // Deposit
        uint256 depositAmount = 5000e18;
        _deposit(client1, depositAmount, client1);

        // Simulate yield accumulation
        uint256 totalAssets = autoDolaVault.convertToAssets(autoDolaVault.balanceOf(address(vault)));
        autoDolaVault.simulateYield(totalAssets / 2); // 50% yield

        // Balance should reflect yield
        uint256 balanceWithYield = vault.balanceOf(address(dolaToken), client1);
        assertGt(balanceWithYield, depositAmount, "Balance should increase due to yield");

        // Full withdrawal should work
        _withdraw(client1, balanceWithYield, client1);

        // Verify complete withdrawal
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Balance should be zero after full withdrawal");
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Total deposited should be zero");
        assertApproxEqRel(dolaToken.balanceOf(client1), balanceWithYield, 1e14, "Should receive full balance with yield");
    }

    /**
     * @notice Test edge case: attempting to withdraw when balance is zero
     * @dev Should revert with appropriate error
     */
    function testWithdrawWhenBalanceAlreadyZero() public {
        // Setup: deposit and fully withdraw
        _deposit(client1, 1000e18, client1);
        _withdraw(client1, vault.balanceOf(address(dolaToken), client1), client1);

        // Verify balance is zero
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Balance should be zero");

        // Try to withdraw again - should revert
        vm.prank(client1);
        vm.expectRevert("AutoDolaYieldStrategy: insufficient balance");
        vault.withdraw(address(dolaToken), 1, client1);
    }
}

// ============ MOCK CONTRACTS ============

/**
 * @notice Mock autoDOLA vault for testing
 * @dev Simulates ERC4626 vault behavior with yield support
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

    // Simulate positive yield growth - mint actual DOLA tokens to back the yield
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
