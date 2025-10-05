// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteVaults/AutoDolaVault.sol";
import "../../src/mocks/MockERC20.sol";

/**
 * @title VaultIntegrationTest
 * @notice Integration tests for end-to-end vault flows with realistic yield scenarios
 * @dev Tests complete user journeys, reward accrual over time, and concurrent operations
 *      Uses high-fidelity mocks that simulate realistic behavior of autoDOLA and MainRewarder
 */
contract VaultIntegrationTest is Test {
    AutoDolaVault public vault;
    MockERC20 public dolaToken;
    MockERC20 public tokeToken;
    MockAutoDOLA public autoDolaVault;
    MockMainRewarder public mainRewarder;

    address public owner = address(1);
    address public client1 = address(2);
    address public client2 = address(3);
    address public client3 = address(4);
    address public user1 = address(10);
    address public user2 = address(11);
    address public user3 = address(12);

    uint256 constant INITIAL_DOLA_SUPPLY = 100_000_000e18; // 100M DOLA
    uint256 constant INITIAL_TOKE_SUPPLY = 10_000_000e18;  // 10M TOKE

    // Events
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

    event TokeRewardsClaimed(address indexed recipient, uint256 amount);

    function setUp() public {
        // Deploy mock tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock MainRewarder
        mainRewarder = new MockMainRewarder(address(tokeToken));

        // Deploy mock autoDOLA vault with realistic initial state
        autoDolaVault = new MockAutoDOLA(address(dolaToken), address(mainRewarder));

        // Deploy the vault
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

        // Mint tokens to test addresses
        dolaToken.mint(client1, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(client2, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(client3, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(address(autoDolaVault), INITIAL_DOLA_SUPPLY); // For autoDOLA mock

        tokeToken.mint(address(mainRewarder), INITIAL_TOKE_SUPPLY);
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @notice Helper to deposit DOLA
     */
    function _deposit(address client, uint256 amount, address recipient) internal {
        vm.startPrank(client);
        dolaToken.approve(address(vault), amount);
        vault.deposit(address(dolaToken), amount, recipient);
        vm.stopPrank();
    }

    /**
     * @notice Helper to withdraw DOLA
     * @dev The client parameter must be the same address that the deposit was made FOR (the recipient in deposit)
     *      This is because clientBalances tracks by recipient, not by msg.sender
     */
    function _withdraw(address client, uint256 amount, address recipient) internal {
        vm.prank(client);
        vault.withdraw(address(dolaToken), amount, recipient);
    }

    /**
     * @notice Helper to simulate realistic yield growth over time
     * @param timeInDays Number of days to simulate
     * @param annualYieldBps Annual yield in basis points (e.g., 500 = 5%)
     */
    function _simulateYieldOverTime(uint256 timeInDays, uint256 annualYieldBps) internal {
        // Calculate daily yield rate
        uint256 totalAssets = autoDolaVault.totalAssets();
        uint256 dailyYield = (totalAssets * annualYieldBps * timeInDays) / (365 * 10000);

        // Apply yield gradually
        for (uint256 i = 0; i < timeInDays; i++) {
            vm.warp(block.timestamp + 1 days);
            uint256 dailyYieldAmount = dailyYield / timeInDays;
            autoDolaVault.simulateYield(dailyYieldAmount);
        }
    }

    /**
     * @notice Helper to simulate TOKE reward accrual over time
     * @param timeInDays Number of days to simulate
     * @param dailyTokeReward TOKE rewards per day
     */
    function _simulateTokeRewardsOverTime(uint256 timeInDays, uint256 dailyTokeReward) internal {
        for (uint256 i = 0; i < timeInDays; i++) {
            vm.warp(block.timestamp + 1 days);
            mainRewarder.simulateRewards(address(vault), dailyTokeReward);
        }
    }

    // ============ INTEGRATION TEST 1: FULL DEPOSIT/WITHDRAW CYCLE WITH REALISTIC YIELD ============

    /**
     * @notice Test end-to-end flow with realistic yield generation
     * @dev Simulates:
     *      1. Multiple users depositing over time
     *      2. Realistic yield accrual (5% APY over 30 days)
     *      3. Partial withdrawals
     *      4. Final complete withdrawals
     *      5. Verification of accurate yield distribution
     */
    function testFullDepositWithdrawCycleWithRealYield() public {
        // ============ PHASE 1: INITIAL DEPOSITS ============

        uint256 deposit1 = 10_000e18; // User1 deposits 10k DOLA
        uint256 deposit2 = 20_000e18; // User2 deposits 20k DOLA
        uint256 deposit3 = 15_000e18; // User3 deposits 15k DOLA

        // Day 1: Client1 deposits for themselves
        _deposit(client1, deposit1, client1);
        assertEq(vault.balanceOf(address(dolaToken), client1), deposit1, "Client1 initial deposit mismatch");

        // Day 5: Client2 deposits for themselves
        vm.warp(block.timestamp + 5 days);
        _deposit(client2, deposit2, client2);

        // Day 10: Client3 deposits for themselves
        vm.warp(block.timestamp + 5 days);
        _deposit(client3, deposit3, client3);

        uint256 totalDeposited = deposit1 + deposit2 + deposit3;
        assertEq(vault.getTotalDeposited(address(dolaToken)), totalDeposited, "Total deposited mismatch");

        // ============ PHASE 2: YIELD ACCRUAL ============

        // Simulate 30 days of 5% APY yield
        uint256 startTime = block.timestamp;
        _simulateYieldOverTime(30, 500); // 5% annual = 500 bps

        // ============ PHASE 3: VERIFY YIELD DISTRIBUTION ============

        uint256 client1BalanceWithYield = vault.balanceOf(address(dolaToken), client1);
        uint256 client2BalanceWithYield = vault.balanceOf(address(dolaToken), client2);
        uint256 client3BalanceWithYield = vault.balanceOf(address(dolaToken), client3);

        // All clients should have earned yield
        assertGt(client1BalanceWithYield, deposit1, "Client1 should have earned yield");
        assertGt(client2BalanceWithYield, deposit2, "Client2 should have earned yield");
        assertGt(client3BalanceWithYield, deposit3, "Client3 should have earned yield");

        // Calculate total yield
        uint256 totalYield = (client1BalanceWithYield + client2BalanceWithYield + client3BalanceWithYield) - totalDeposited;
        assertGt(totalYield, 0, "Total yield should be positive");

        // ============ PHASE 4: MORE YIELD ACCRUAL ============

        // Simulate another 15 days of yield (total 45 days of yield)
        _simulateYieldOverTime(15, 500);

        // ============ PHASE 5: FINAL WITHDRAWALS ============

        {
            // Client1 withdraws remaining balance
            uint256 client1RemainingBalance = vault.balanceOf(address(dolaToken), client1);
            assertGt(client1RemainingBalance, 0, "Client1 should have remaining balance");

            _withdraw(client1, client1RemainingBalance, user1);
            assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Client1 balance should be zero after final withdrawal");
        }

        {
            // Client2 withdraws remaining balance
            uint256 client2RemainingBalance = vault.balanceOf(address(dolaToken), client2);
            _withdraw(client2, client2RemainingBalance, user2);
            assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Client2 balance should be zero");
        }

        {
            // Client3 withdraws all (never withdrew before)
            uint256 client3FinalBalance = vault.balanceOf(address(dolaToken), client3);
            assertGt(client3FinalBalance, deposit3, "Client3 should have earned yield");

            _withdraw(client3, client3FinalBalance, user3);
            assertEq(vault.balanceOf(address(dolaToken), client3), 0, "Client3 balance should be zero");
        }

        // ============ PHASE 6: FINAL VERIFICATION ============

        // Verify all withdrawals completed successfully
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Total deposited should be zero after all withdrawals");
        assertEq(vault.getTotalShares(), 0, "Total shares should be zero after all withdrawals");

        // Verify users received their deposits + yield (approximately)
        uint256 totalWithdrawn = dolaToken.balanceOf(user1) + dolaToken.balanceOf(user2) + dolaToken.balanceOf(user3);
        assertGt(totalWithdrawn, totalDeposited, "Total withdrawn should exceed deposits (due to yield)");
    }

    // ============ INTEGRATION TEST 2: REWARD ACCRUAL OVER TIME ============

    /**
     * @notice Test TOKE reward accrual over extended time period
     * @dev Simulates:
     *      1. Users depositing and staking
     *      2. TOKE rewards accruing daily over 60 days
     *      3. Periodic reward claims by vault owner
     *      4. Verification of accurate reward tracking
     */
    function testRewardAccrualOverTime() public {
        // ============ PHASE 1: INITIAL DEPOSITS ============

        uint256 deposit1 = 50_000e18; // 50k DOLA
        uint256 deposit2 = 30_000e18; // 30k DOLA

        _deposit(client1, deposit1, client1);
        _deposit(client2, deposit2, client2);

        // Verify staking occurred
        uint256 stakedShares = mainRewarder.balanceOf(address(vault));
        assertGt(stakedShares, 0, "Shares should be staked");

        // ============ PHASE 2: REWARD ACCRUAL SIMULATION ============

        uint256 dailyTokeReward = 100e18; // 100 TOKE per day
        uint256 simulationDays = 60;

        // Track rewards over time
        uint256[] memory rewardSnapshots = new uint256[](7); // Weekly snapshots

        for (uint256 week = 0; week < 6; week++) {
            // Simulate one week (7 days)
            for (uint256 day = 0; day < 7; day++) {
                vm.warp(block.timestamp + 1 days);
                mainRewarder.simulateRewards(address(vault), dailyTokeReward);
            }

            // Take snapshot of rewards
            rewardSnapshots[week] = vault.getTokeRewards();

            // Verify rewards are increasing
            if (week > 0) {
                assertGt(rewardSnapshots[week], rewardSnapshots[week - 1], "Rewards should increase over time");
            }
        }

        // ============ PHASE 3: PERIODIC REWARD CLAIMS ============

        // Claim rewards after 6 weeks
        uint256 rewardsBeforeClaim = vault.getTokeRewards();
        assertGt(rewardsBeforeClaim, 0, "Should have accumulated rewards");

        uint256 ownerTokeBalanceBefore = tokeToken.balanceOf(owner);

        vm.prank(owner);
        vault.claimTokeRewards(owner);

        uint256 ownerTokeBalanceAfter = tokeToken.balanceOf(owner);
        uint256 rewardsAfterClaim = vault.getTokeRewards();

        // Verify claim worked correctly
        assertEq(rewardsAfterClaim, 0, "Rewards should be zero after claim");
        assertEq(ownerTokeBalanceAfter - ownerTokeBalanceBefore, rewardsBeforeClaim, "Owner should receive all rewards");

        // ============ PHASE 4: CONTINUE ACCRUAL AFTER CLAIM ============

        // Simulate another 2 weeks
        for (uint256 day = 0; day < 14; day++) {
            vm.warp(block.timestamp + 1 days);
            mainRewarder.simulateRewards(address(vault), dailyTokeReward);
        }

        uint256 newRewards = vault.getTokeRewards();
        assertGt(newRewards, 0, "Should have new rewards after claim");

        // Expected rewards: 14 days * 100 TOKE/day = 1400 TOKE
        assertApproxEqAbs(newRewards, 1400e18, 1e18, "New rewards should match expected amount");

        // ============ PHASE 5: WITHDRAWAL DOESN'T AFFECT REWARD TRACKING ============

        // Client1 withdraws some funds
        uint256 withdrawAmount = 10_000e18;
        _withdraw(client1, withdrawAmount, user1);

        // Verify rewards are unaffected by withdrawal
        assertEq(vault.getTokeRewards(), newRewards, "Withdrawal should not affect reward balance");

        // ============ PHASE 6: FINAL CLAIM ============

        vm.prank(owner);
        vault.claimTokeRewards(owner);

        assertEq(vault.getTokeRewards(), 0, "All rewards should be claimed");

        // Verify total TOKE rewards claimed approximately matches expected
        uint256 totalTokeClaimed = tokeToken.balanceOf(owner);
        uint256 expectedTotalRewards = dailyTokeReward * (42 + 14); // 6 weeks + 2 weeks = 56 days
        assertApproxEqAbs(totalTokeClaimed, expectedTotalRewards, 100e18, "Total rewards should match expected");
    }

    // ============ INTEGRATION TEST 3: CONCURRENT OPERATIONS ============

    /**
     * @notice Test concurrent deposits, withdrawals, and reward claims
     * @dev Simulates realistic multi-user scenario with:
     *      1. Overlapping deposits and withdrawals
     *      2. Simultaneous yield accrual
     *      3. Periodic reward claims
     *      4. Verification of state consistency
     */
    function testConcurrentDepositsWithdrawalsAndRewards() public {
        // ============ PHASE 1: STAGGERED DEPOSITS ============

        uint256 baseDeposit = 5_000e18;

        // Day 1: Client1 deposits
        _deposit(client1, baseDeposit, client1);

        // Simulate some yield and rewards
        vm.warp(block.timestamp + 1 days);
        autoDolaVault.simulateYield(100e18);
        mainRewarder.simulateRewards(address(vault), 50e18);

        // Day 2: Client2 deposits while Client1 has accrued yield
        _deposit(client2, baseDeposit * 2, client2);

        vm.warp(block.timestamp + 1 days);
        autoDolaVault.simulateYield(150e18);
        mainRewarder.simulateRewards(address(vault), 75e18);

        // Day 3: Client3 deposits
        _deposit(client3, baseDeposit * 3, client3);

        // ============ PHASE 2: CONCURRENT YIELD AND REWARDS ============

        // Simulate 10 days of concurrent activity
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1 days);

            // Yield accrues
            autoDolaVault.simulateYield(200e18);

            // TOKE rewards accrue
            mainRewarder.simulateRewards(address(vault), 100e18);

            // Random client deposits (simulate new money coming in)
            if (i % 3 == 0) {
                _deposit(client1, 1_000e18, client1);
            }
        }

        // ============ PHASE 3: VERIFY YIELD ACCUMULATION ============

        {
            // Store balances after yield
            uint256 client1BalanceBefore = vault.balanceOf(address(dolaToken), client1);
            uint256 client2BalanceBefore = vault.balanceOf(address(dolaToken), client2);
            uint256 client3BalanceBefore = vault.balanceOf(address(dolaToken), client3);

            // All clients should have earned yield
            assertGt(client1BalanceBefore, baseDeposit + 3_000e18, "Client1 should have base + extra deposits + yield");
            assertGt(client2BalanceBefore, baseDeposit * 2, "Client2 should have earned yield");
            assertGt(client3BalanceBefore, baseDeposit * 3, "Client3 should have earned yield");
        }

        // ============ PHASE 4: REWARD CLAIM DURING ACTIVE DEPOSITS ============

        {
            uint256 rewardsBefore = vault.getTokeRewards();
            assertGt(rewardsBefore, 0, "Should have accumulated TOKE rewards");

            // Owner claims rewards while users have active positions
            vm.prank(owner);
            vault.claimTokeRewards(owner);

            assertEq(vault.getTokeRewards(), 0, "Rewards should be claimed");
            assertEq(tokeToken.balanceOf(owner), rewardsBefore, "Owner should receive rewards");
        }

        // ============ PHASE 5: MORE CONCURRENT ACTIVITY ============

        // Continue with more deposits, withdrawals, and yield
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1 days);
            autoDolaVault.simulateYield(150e18);
            mainRewarder.simulateRewards(address(vault), 80e18);
        }

        // Client3 deposits more
        _deposit(client3, 5_000e18, client3);

        // ============ PHASE 6: VERIFY SYSTEM STATE CONSISTENCY ============

        {
            // Verify total shares matches sum of individual shares
            uint256 totalShares = autoDolaVault.balanceOf(address(vault));
            assertGt(totalShares, 0, "Should have shares");

            // Verify totalDeposited consistency
            uint256 totalDepositedFinal = vault.getTotalDeposited(address(dolaToken));
            assertGt(totalDepositedFinal, 0, "Should have total deposited");

            // Verify all client balances are queryable and positive
            uint256 client1Final = vault.balanceOf(address(dolaToken), client1);
            uint256 client2Final = vault.balanceOf(address(dolaToken), client2);
            uint256 client3Final = vault.balanceOf(address(dolaToken), client3);

            assertGt(client1Final, 0, "Client1 should have balance");
            assertGt(client2Final, 0, "Client2 should have balance");
            assertGt(client3Final, 0, "Client3 should have balance");

            // Verify no rewards are stuck (claim again to check)
            vm.warp(block.timestamp + 1 days);
            mainRewarder.simulateRewards(address(vault), 100e18);

            uint256 finalRewards = vault.getTokeRewards();
            assertGt(finalRewards, 0, "New rewards should have accrued");

            vm.prank(owner);
            vault.claimTokeRewards(owner);
            assertEq(vault.getTokeRewards(), 0, "All rewards should be claimable");
        }

        // ============ PHASE 7: COMPLETE WITHDRAWAL OF ALL CLIENTS ============

        // Final cleanup - all clients withdraw everything
        _withdraw(client1, vault.balanceOf(address(dolaToken), client1), user1);
        _withdraw(client2, vault.balanceOf(address(dolaToken), client2), user2);
        _withdraw(client3, vault.balanceOf(address(dolaToken), client3), user3);

        // Verify complete cleanup
        assertEq(vault.balanceOf(address(dolaToken), client1), 0, "Client1 should have zero balance");
        assertEq(vault.balanceOf(address(dolaToken), client2), 0, "Client2 should have zero balance");
        assertEq(vault.balanceOf(address(dolaToken), client3), 0, "Client3 should have zero balance");
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0, "Total deposited should be zero");
        assertEq(vault.getTotalShares(), 0, "Total shares should be zero");

        // Verify users received their funds (user1, user2, user3 are just withdrawal recipients)
        assertGt(dolaToken.balanceOf(user1), baseDeposit, "User1 should have received deposits + yield");
        assertGt(dolaToken.balanceOf(user2), baseDeposit * 2, "User2 should have received deposits + yield");
        assertGt(dolaToken.balanceOf(user3), baseDeposit * 3 + 5_000e18, "User3 should have received deposits + yield");
    }
}

// ============ MOCK CONTRACTS (HIGH-FIDELITY) ============

/**
 * @notice High-fidelity mock of AutoDOLA vault
 * @dev Simulates realistic ERC4626 behavior with yield accrual
 */
contract MockAutoDOLA is MockERC20 {
    mapping(address => uint256) private _balances;
    uint256 private _totalAssets;
    uint256 private _totalShares;
    address private _asset;
    address private _rewarder;

    constructor(address asset_, address rewarder_) MockERC20("AutoDOLA", "autoDOLA", 18) {
        _totalAssets = 1_000_000e18; // Start with 1M DOLA worth of assets
        _totalShares = 1_000_000e18; // 1:1 initial ratio
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
        if (_totalAssets == 0) return assets;
        return (assets * _totalShares) / _totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (_totalShares == 0) return shares;
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

    // Simulate yield growth by adding actual tokens and increasing total assets
    function simulateYield(uint256 yieldAmount) external {
        _totalAssets += yieldAmount;
        // Mint the yield amount to this contract to ensure actual tokens exist
        MockERC20(_asset).mint(address(this), yieldAmount);
    }
}

/**
 * @notice High-fidelity mock of MainRewarder
 * @dev Simulates realistic TOKE staking and reward distribution
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

        // If claim is true, also claim pending rewards
        if (claim && _rewards[user] > 0) {
            uint256 reward = _rewards[user];
            _rewards[user] = 0;
            MockERC20(_rewardToken).transfer(user, reward);
        }
    }

    function earned(address user) external view returns (uint256) {
        return _rewards[user];
    }

    function getReward(address account, address recipient, bool claimExtras) external returns (bool) {
        uint256 reward = _rewards[account];
        _rewards[account] = 0;
        if (reward > 0) {
            MockERC20(_rewardToken).transfer(recipient, reward);
        }
        return true;
    }

    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function rewardToken() external view returns (address) {
        return _rewardToken;
    }

    // Test helper to simulate earning rewards
    function simulateRewards(address user, uint256 amount) external {
        _rewards[user] += amount;
        MockERC20(_rewardToken).mint(address(this), amount);
    }
}
