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

    function testAutoDolaVaultSurplusWithYield() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Simulate yield accrual in autoDola (10% yield)
        autoDola.accrueYield(100e18);

        // Get vault balance (should include yield)
        uint256 vaultBalance = autoDolaVault.balanceOf(address(dolaToken), client1);

        // Vault balance should be approximately 1100 DOLA (1000 + 10% yield)
        assertGt(vaultBalance, 1000e18, "Vault balance should include yield");

        // Calculate surplus (client's internal accounting is still 1000)
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Surplus should be the yield (approximately 100 DOLA)
        assertGt(surplus, 0, "AutoDolaYieldStrategy surplus should be positive");
        assertApproxEqRel(surplus, 100e18, 0.01e18, "Surplus should be approximately 100 DOLA");
    }

    function testAutoDolaVaultSurplusNoYield() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // No yield accrual

        // Get vault balance
        uint256 vaultBalance = autoDolaVault.balanceOf(address(dolaToken), client1);

        // Calculate surplus (internal balance matches vault)
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            vaultBalance
        );

        assertEq(surplus, 0, "AutoDolaYieldStrategy surplus should be 0 without yield");
    }

    function testAutoDolaVaultSurplusMultipleClients() public {
        // Client 1 deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Client 2 deposits 2000 DOLA
        vm.startPrank(client2);
        dolaToken.approve(address(autoDolaVault), 2000e18);
        autoDolaVault.deposit(address(dolaToken), 2000e18, client2);
        vm.stopPrank();

        // Simulate yield accrual (10% = 300 DOLA total)
        autoDola.accrueYield(300e18);

        // Calculate surplus for both clients
        // Client 1 should get 1/3 of yield (100 DOLA)
        uint256 surplus1 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Client 2 should get 2/3 of yield (200 DOLA)
        uint256 surplus2 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client2,
            2000e18
        );

        // Verify proportional surplus distribution
        assertGt(surplus1, 0, "Client 1 should have surplus");
        assertGt(surplus2, 0, "Client 2 should have surplus");
        assertApproxEqRel(surplus1, 100e18, 0.01e18, "Client 1 surplus should be ~100 DOLA");
        assertApproxEqRel(surplus2, 200e18, 0.01e18, "Client 2 surplus should be ~200 DOLA");
    }

    // ============ CROSS-VAULT TESTS ============

    function testSurplusTrackerWorksWithMultipleVaultTypes() public {
        MockERC20 testToken = new MockERC20("TEST", "TEST", 18);
        testToken.mint(client1, 10000e18);
        mockVault.setClient(client1, true);

        // Setup MockVault
        vm.startPrank(client1);
        testToken.approve(address(mockVault), 1000e18);
        mockVault.deposit(address(testToken), 1000e18, client1);
        vm.stopPrank();

        // Setup AutoDolaYieldStrategy
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Accrue yield only in AutoDolaYieldStrategy
        autoDola.accrueYield(100e18);

        // Calculate surplus for MockVault
        uint256 mockSurplus = tracker.getSurplus(
            address(mockVault),
            address(testToken),
            client1,
            900e18
        );

        // Calculate surplus for AutoDolaYieldStrategy
        uint256 autoSurplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Verify independent calculations
        assertEq(mockSurplus, 100e18, "MockVault surplus should be 100");
        assertGt(autoSurplus, 0, "AutoDolaYieldStrategy surplus should be positive");
    }

    // ============ REALISTIC SCENARIO TESTS ============

    function testRealisticBehodlerScenario() public {
        // Simulates Behodler's virtualInputTokens vs vault's balanceOf scenario
        // Behodler deposits 10000 DOLA into vault
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 10000e18);
        autoDolaVault.deposit(address(dolaToken), 10000e18, client1);
        vm.stopPrank();

        // Behodler's internal accounting (virtualInputTokens) = 10000
        uint256 behodlerInternalBalance = 10000e18;

        // Time passes, yield accrues (5% = 500 DOLA)
        autoDola.accrueYield(500e18);

        // Calculate harvestable surplus
        uint256 harvestableSurplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            behodlerInternalBalance
        );

        // Verify surplus is the accrued yield
        assertGt(harvestableSurplus, 0, "Should have harvestable surplus");
        assertApproxEqRel(harvestableSurplus, 500e18, 0.01e18, "Surplus should be ~500 DOLA");

        // Verify vault balance includes yield
        uint256 vaultBalance = autoDolaVault.balanceOf(address(dolaToken), client1);
        assertApproxEqRel(vaultBalance, 10500e18, 0.01e18, "Vault should have ~10500 DOLA");
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

    function testHighYieldScenario() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // Simulate very high yield (100% = 1000 DOLA)
        autoDola.accrueYield(1000e18);

        // Calculate surplus
        uint256 surplus = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Surplus should be approximately 1000 DOLA
        assertApproxEqRel(surplus, 1000e18, 0.01e18, "Surplus should handle high yield");
    }

    function testMultipleYieldAccruals() public {
        // Client deposits 1000 DOLA
        vm.startPrank(client1);
        dolaToken.approve(address(autoDolaVault), 1000e18);
        autoDolaVault.deposit(address(dolaToken), 1000e18, client1);
        vm.stopPrank();

        // First yield accrual (5% = 50 DOLA)
        autoDola.accrueYield(50e18);

        uint256 surplus1 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Second yield accrual (another 5% = 50 DOLA)
        autoDola.accrueYield(50e18);

        uint256 surplus2 = tracker.getSurplus(
            address(autoDolaVault),
            address(dolaToken),
            client1,
            1000e18
        );

        // Second surplus should be larger than first
        assertGt(surplus2, surplus1, "Surplus should accumulate over time");
        assertApproxEqRel(surplus2, 100e18, 0.01e18, "Final surplus should be ~100 DOLA");
    }
}
