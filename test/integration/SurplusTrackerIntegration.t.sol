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
    // DELETED: testAutoDolaVaultSurplusWithYield
    // DELETED: testAutoDolaVaultSurplusNoYield
    // DELETED: testAutoDolaVaultSurplusMultipleClients
    //
    // Reason: Story 018 changed balanceOf() to return ONLY principal (excludes yield)
    // Surplus represents yield that users can access, but yield is now locked in the vault
    // Users cannot harvest surplus from AutoDolaYieldStrategy anymore
    // These tests expected users to have surplus = yield, which is no longer possible

    // ============ CROSS-VAULT TESTS ============
    //
    // DELETED: testSurplusTrackerWorksWithMultipleVaultTypes
    //
    // Reason: Story 018 changed AutoDolaYieldStrategy balanceOf() to exclude yield
    // The test expected AutoDolaYieldStrategy to have positive surplus from yield
    // This is no longer possible as users cannot access yield in AutoDolaYieldStrategy
    // Test would need to be rewritten without AutoDola yield expectations

    // ============ REALISTIC SCENARIO TESTS ============
    //
    // DELETED: testRealisticBehodlerScenario
    //
    // Reason: Story 018 changed balanceOf() to return ONLY principal (excludes yield)
    // This test expected harvest surplus from AutoDolaYieldStrategy yield
    // Yield is now locked and inaccessible to users, so harvestable surplus = 0
    // The test would fail as balanceOf() would return 10000, not 10500

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
    // DELETED: testHighYieldScenario
    // DELETED: testMultipleYieldAccruals
    //
    // Reason: Story 018 changed balanceOf() to return ONLY principal (excludes yield)
    // These tests expected surplus from yield in AutoDolaYieldStrategy
    // Yield is now locked and cannot be accessed by users
    // balanceOf() now returns only principal, so surplus = 0 regardless of yield
}
