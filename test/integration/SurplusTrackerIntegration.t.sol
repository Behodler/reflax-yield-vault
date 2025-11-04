// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/SurplusTracker.sol";
import "../../src/mocks/MockVault.sol";
import "../../src/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";

/**
 * @title MockAutoDola
 * @notice Mock implementation of IAutoDOLA for testing
 */
contract MockAutoDola {
    MockERC20 public asset;
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalAssets;

    constructor(address _asset) {
        asset = MockERC20(_asset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        asset.transferFrom(msg.sender, address(this), assets);
        uint256 sharesToMint = totalShares == 0 ? assets : (assets * totalShares) / totalAssets;
        shares[receiver] += sharesToMint;
        totalShares += sharesToMint;
        totalAssets += assets;
        return sharesToMint;
    }

    function redeem(uint256 sharesToBurn, address receiver, address owner) external returns (uint256) {
        require(shares[owner] >= sharesToBurn, "Insufficient shares");
        uint256 assetsToReturn = (sharesToBurn * totalAssets) / totalShares;
        shares[owner] -= sharesToBurn;
        totalShares -= sharesToBurn;
        totalAssets -= assetsToReturn;
        asset.transfer(receiver, assetsToReturn);
        return assetsToReturn;
    }

    function convertToAssets(uint256 sharesToConvert) external view returns (uint256) {
        if (totalShares == 0) return sharesToConvert;
        return (sharesToConvert * totalAssets) / totalShares;
    }

    function convertToShares(uint256 assetsToConvert) external view returns (uint256) {
        if (totalAssets == 0) return assetsToConvert;
        return (assetsToConvert * totalShares) / totalAssets;
    }

    function balanceOf(address account) external view returns (uint256) {
        return shares[account];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        // Mock approval
        return true;
    }

    // Helper function to simulate yield accrual
    function accrueYield(uint256 yieldAmount) external {
        asset.mint(address(this), yieldAmount);
        totalAssets += yieldAmount;
    }
}

/**
 * @title MockMainRewarder
 * @notice Mock implementation of IMainRewarder for testing
 */
contract MockMainRewarder {
    mapping(address => uint256) public stakedBalances;

    function stake(address account, uint256 amount) external {
        stakedBalances[account] += amount;
    }

    function withdraw(address account, uint256 amount, bool claim) external {
        stakedBalances[account] -= amount;
    }

    function getReward(address account, address recipient, bool claim) external returns (bool) {
        return true;
    }

    function earned(address account) external view returns (uint256) {
        return 0;
    }

    function balanceOf(address account) external view returns (uint256) {
        return stakedBalances[account];
    }
}

/**
 * @title SurplusTrackerIntegrationTest
 * @notice Integration tests for SurplusTracker with multiple vault types
 */
contract SurplusTrackerIntegrationTest is Test {
    SurplusTracker public tracker;
    MockVault public mockVault;
    AutoDolaYieldStrategy public autoDolaVault;

    MockERC20 public dolaToken;
    MockERC20 public tokeToken;
    MockAutoDola public autoDola;
    MockMainRewarder public mainRewarder;

    address public owner;
    address public client1;
    address public client2;

    function setUp() public {
        owner = address(this);
        client1 = address(0x1);
        client2 = address(0x2);

        // Deploy tracker
        tracker = new SurplusTracker();

        // Deploy mock tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock AutoDola and MainRewarder
        autoDola = new MockAutoDola(address(dolaToken));
        mainRewarder = new MockMainRewarder();

        // Deploy MockVault
        mockVault = new MockVault(owner);
        mockVault.setClient(client1, true);
        mockVault.setClient(client2, true);

        // Deploy AutoDolaYieldStrategy
        autoDolaVault = new AutoDolaYieldStrategy(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDola),
            address(mainRewarder)
        );
        autoDolaVault.setClient(client1, true);
        autoDolaVault.setClient(client2, true);

        // Mint tokens to clients
        dolaToken.mint(client1, 10000e18);
        dolaToken.mint(client2, 10000e18);

        MockERC20 testToken = new MockERC20("TEST", "TEST", 18);
        testToken.mint(client1, 10000e18);
        testToken.mint(client2, 10000e18);
    }

    // ============ MOCKVAULT INTEGRATION TESTS ============

    function testMockVaultSurplusCalculation() public {
        MockERC20 testToken = new MockERC20("TEST", "TEST", 18);
        testToken.mint(client1, 10000e18);
        mockVault.setClient(client1, true);

        // Client deposits 1000 tokens
        vm.startPrank(client1);
        testToken.approve(address(mockVault), 1000e18);
        mockVault.deposit(address(testToken), 1000e18, client1);
        vm.stopPrank();

        // Calculate surplus (internal balance = 900)
        uint256 surplus = tracker.getSurplus(
            address(mockVault),
            address(testToken),
            client1,
            900e18
        );

        assertEq(surplus, 100e18, "MockVault surplus should be 100");
    }

    function testMockVaultNoSurplus() public {
        MockERC20 testToken = new MockERC20("TEST", "TEST", 18);
        testToken.mint(client1, 10000e18);
        mockVault.setClient(client1, true);

        // Client deposits 1000 tokens
        vm.startPrank(client1);
        testToken.approve(address(mockVault), 1000e18);
        mockVault.deposit(address(testToken), 1000e18, client1);
        vm.stopPrank();

        // Calculate surplus (internal balance matches vault)
        uint256 surplus = tracker.getSurplus(
            address(mockVault),
            address(testToken),
            client1,
            1000e18
        );

        assertEq(surplus, 0, "MockVault surplus should be 0");
    }

    // ============ AUTODOLAVAULT INTEGRATION TESTS ============
    //
    // RESTORED in Story 022: Now that totalBalanceOf() includes yield, we can correctly
    // calculate surplus from AutoDolaYieldStrategy. SurplusTracker now uses totalBalanceOf()
    // which returns principal + yield, making surplus calculation work as expected.

    function testAutoDolaVaultSurplusWithYield() public {
        // Client1 deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Verify principal is tracked correctly
        assertEq(autoDolaVault.principalOf(address(dolaToken), client1), 1000e18);

        // Simulate yield accrual in autoDola (5% yield = 50 DOLA)
        autoDola.accrueYield(50e18);

        // totalBalanceOf should now include yield
        uint256 totalBalance = autoDolaVault.totalBalanceOf(address(dolaToken), client1);
        assertGt(totalBalance, 1000e18, "Total balance should include yield");

        // Calculate surplus with internal balance = principal (1000)
        // Surplus = totalBalanceOf() - clientInternalBalance
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Surplus should approximately equal the yield (50 DOLA)
        // Use approximate equality due to potential rounding
        assertApproxEqAbs(surplus, 50e18, 1e18, "Surplus should approximately equal yield");
        assertGt(surplus, 0, "Surplus should be positive when yield exists");
    }

    function testAutoDolaVaultSurplusNoYield() public {
        // Client1 deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // No yield accrual - totalBalanceOf should equal principal
        assertEq(autoDolaVault.principalOf(address(dolaToken), client1), 1000e18);
        assertApproxEqAbs(
            autoDolaVault.totalBalanceOf(address(dolaToken), client1),
            1000e18,
            1,
            "Total balance should equal principal with no yield"
        );

        // Calculate surplus with internal balance matching principal
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Surplus should be 0 when no yield has accrued
        assertEq(surplus, 0, "Surplus should be 0 with no yield");
    }

    function testAutoDolaVaultSurplusMultipleClients() public {
        // Client1 deposits 2000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 2000e18);
        autoDolaVault.deposit(address(dolaToken), 2000e18, client1);
        vm.stopPrank();

        // Client2 deposits 1000 DOLA
        vm.startPrank(client2);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client2);
        vm.stopPrank();

        // Simulate yield accrual (10% yield on 3000 total = 300 DOLA)
        autoDola.accrueYield(300e18);

        // Calculate surplus for client1 (should get 2/3 of yield = 200 DOLA)
        uint256 surplus1 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            2000e18
        );

        // Calculate surplus for client2 (should get 1/3 of yield = 100 DOLA)
        uint256 surplus2 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client2,
            1000e18
        );

        // Verify proportional surplus distribution
        assertApproxEqAbs(surplus1, 200e18, 2e18, "Client1 should get ~200 DOLA surplus");
        assertApproxEqAbs(surplus2, 100e18, 1e18, "Client2 should get ~100 DOLA surplus");

        // Ratio should be approximately 2:1
        assertApproxEqAbs(surplus1, surplus2 * 2, 2e18, "Surplus ratio should match deposit ratio");
    }

    // ============ CROSS-VAULT TESTS ============
    //
    // RESTORED in Story 022: Now that SurplusTracker uses totalBalanceOf(), it correctly
    // works with all vault types including AutoDolaYieldStrategy with yield.

    function testSurplusTrackerWorksWithMultipleVaultTypes() public {
        MockERC20 testToken = new MockERC20("TEST", "TEST", 18);
        testToken.mint(client1, 10000e18);

        // Test with MockVault (simple vault without yield)
        mockVault.setClient(client1, true);
        vm.startPrank(client1);
        testToken.approve(address(mockVault), 1000e18);
        mockVault.deposit(address(testToken), 1000e18, client1);
        vm.stopPrank();

        uint256 mockVaultSurplus = tracker.getSurplus(
            address(mockVault),
            address(testToken),
            client1,
            900e18 // Internal balance is 900
        );
        assertEq(mockVaultSurplus, 100e18, "MockVault surplus calculation");

        // Test with AutoDolaYieldStrategy (yield-generating vault)
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Accrue yield
        autoDola.accrueYield(100e18);

        uint256 autoDolaVaultSurplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18 // Internal balance is principal only
        );
        assertGt(autoDolaVaultSurplus, 0, "AutoDolaVault should have positive surplus from yield");
        assertApproxEqAbs(autoDolaVaultSurplus, 100e18, 2e18, "AutoDolaVault surplus should approximately equal yield");
    }

    // ============ REALISTIC SCENARIO TESTS ============
    //
    // RESTORED in Story 022: Now that SurplusTracker uses totalBalanceOf(), we can correctly
    // identify harvestable surplus from AutoDolaYieldStrategy yield.

    function testRealisticBehodlerScenario() public {
        // Behodler has virtualInputTokens = 10000 (internal accounting)
        // User deposits 10000 DOLA into AutoDolaYieldStrategy
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 10000e18);
        autoDolaVault.deposit(address(dolaToken), 10000e18, client1);
        vm.stopPrank();

        // Verify principal matches deposit
        assertEq(autoDolaVault.principalOf(address(dolaToken), client1), 10000e18);

        // AutoDola vault accrues 5% yield (500 DOLA)
        autoDola.accrueYield(500e18);

        // Now totalBalanceOf should return ~10500 (principal + yield)
        uint256 totalBalance = autoDolaVault.totalBalanceOf(address(dolaToken), client1);
        assertApproxEqAbs(totalBalance, 10500e18, 10e18, "Total balance should include yield");

        // SurplusTracker calculates surplus
        // Internal balance (virtualInputTokens) = 10000
        // Vault balance (totalBalanceOf) = 10500
        // Surplus = 500 (harvestable yield)
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            10000e18
        );

        // Verify surplus equals the yield
        assertApproxEqAbs(surplus, 500e18, 10e18, "Surplus should equal accrued yield");
        assertGt(surplus, 0, "Surplus should be positive");

        // This surplus can now be harvested via SurplusWithdrawer (future story)
        // Behodler's virtualInputTokens stays at 10000
        // But SurplusWithdrawer can extract the 500 DOLA yield for protocol revenue
    }

    function testSurplusAfterPartialWithdrawal() public {
        // Use MockVault for simpler withdrawal mechanics
        MockERC20 testToken = new MockERC20("TEST", "TEST", 18);
        testToken.mint(client1, 10000e18);
        mockVault.setClient(client1, true);

        // Client deposits 10000 tokens
        vm.startPrank(client1);
        testToken.approve(address(mockVault), 10000e18);
        mockVault.deposit(address(testToken), 10000e18, client1);
        vm.stopPrank();

        // Initial surplus calculation (internal = 9000, vault = 10000)
        uint256 surplusBefore = tracker.getSurplus(
            address(mockVault),
            address(testToken),
            client1,
            9000e18
        );
        assertEq(surplusBefore, 1000e18, "Initial surplus should be 1000");

        // Client withdraws 2000 tokens
        vm.prank(client1);
        mockVault.withdraw(address(testToken), 2000e18, client1);

        // After withdrawal, vault has 8000 tokens
        // If client's internal accounting is now 7000, surplus should be 1000
        uint256 surplusAfter = tracker.getSurplus(
            address(mockVault),
            address(testToken),
            client1,
            7000e18
        );

        // Surplus should still be 1000 (assuming proportional internal accounting update)
        assertEq(surplusAfter, 1000e18, "Surplus should remain after withdrawal");
    }

    // ============ STRESS TESTS ============
    //
    // RESTORED in Story 022: High yield and multiple accrual scenarios now work correctly
    // because SurplusTracker uses totalBalanceOf() which includes yield.

    function testHighYieldScenario() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Simulate extremely high yield (100% return)
        autoDola.accrueYield(1000e18);

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Surplus should approximately equal the high yield
        assertApproxEqAbs(surplus, 1000e18, 20e18, "High yield scenario surplus");
        assertGt(surplus, 900e18, "Surplus should reflect substantial yield");
    }

    function testMultipleYieldAccruals() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // First yield accrual (5%)
        autoDola.accrueYield(50e18);

        uint256 surplus1 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );
        assertApproxEqAbs(surplus1, 50e18, 2e18, "First accrual surplus");

        // Second yield accrual (another 5%)
        autoDola.accrueYield(50e18);

        uint256 surplus2 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );
        assertApproxEqAbs(surplus2, 100e18, 3e18, "Cumulative surplus after second accrual");

        // Third yield accrual (10%)
        autoDola.accrueYield(100e18);

        uint256 surplus3 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );
        assertApproxEqAbs(surplus3, 200e18, 5e18, "Cumulative surplus after third accrual");
    }
}
