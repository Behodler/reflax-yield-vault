// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteVaults/AutoDolaVault.sol";
import "../src/mocks/MockERC20.sol";

// Mock contracts for testing
contract MockAutoDOLA is MockERC20 {
    mapping(address => uint256) private _balances;
    uint256 private _totalAssets;
    uint256 private _totalShares;
    address private _asset;
    address private _rewarder;

    constructor(address asset_, address rewarder_) MockERC20("AutoDOLA", "autoDOLA", 18) {
        _totalAssets = 1000000e18; // Start with 1M DOLA worth of assets
        _totalShares = 1000000e18; // 1:1 initial ratio
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

    // Simulate yield growth
    function simulateYield(uint256 yieldAmount) external {
        _totalAssets += yieldAmount;
    }
}

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

    function withdraw(address user, uint256 amount) external {
        require(_balances[user] >= amount, "Insufficient staked balance");
        _balances[user] -= amount;
        _totalSupply -= amount;
    }

    function earned(address user) external view returns (uint256) {
        return _rewards[user];
    }

    function getReward(address user) external returns (uint256) {
        uint256 reward = _rewards[user];
        _rewards[user] = 0;
        if (reward > 0) {
            MockERC20(_rewardToken).transfer(user, reward);
        }
        return reward;
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

contract AutoDolaVaultTest is Test {
    AutoDolaVault vault;
    MockERC20 dolaToken;
    MockERC20 tokeToken;
    MockAutoDOLA autoDolaVault;
    MockMainRewarder mainRewarder;

    address owner = address(0x1234);
    address client1 = address(0x5678);
    address client2 = address(0x9ABC);
    address user1 = address(0xDEF0);
    address user2 = address(0x1357);

    uint256 constant INITIAL_DOLA_SUPPLY = 10000000e18; // 10M DOLA
    uint256 constant INITIAL_TOKE_SUPPLY = 1000000e18;  // 1M TOKE

    function setUp() public {
        // Deploy mock tokens
        dolaToken = new MockERC20("DOLA", "DOLA", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock MainRewarder first
        mainRewarder = new MockMainRewarder(address(tokeToken));

        // Deploy mock autoDOLA vault
        autoDolaVault = new MockAutoDOLA(address(dolaToken), address(mainRewarder));

        // Deploy the actual vault
        vm.prank(owner);
        vault = new AutoDolaVault(
            owner,
            address(dolaToken),
            address(tokeToken),
            address(autoDolaVault),
            address(mainRewarder)
        );

        // Mint tokens to test addresses
        dolaToken.mint(client1, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(client2, INITIAL_DOLA_SUPPLY);
        dolaToken.mint(address(autoDolaVault), INITIAL_DOLA_SUPPLY); // For autoDOLA mock

        tokeToken.mint(address(mainRewarder), INITIAL_TOKE_SUPPLY);

        // Authorize clients
        vm.startPrank(owner);
        vault.setClient(client1, true);
        vault.setClient(client2, true);
        vm.stopPrank();
    }

    function testConstructor() public {
        // Test constructor requirements
        vm.expectRevert("AutoDolaVault: DOLA token cannot be zero address");
        new AutoDolaVault(owner, address(0), address(tokeToken), address(autoDolaVault), address(mainRewarder));

        vm.expectRevert("AutoDolaVault: TOKE token cannot be zero address");
        new AutoDolaVault(owner, address(dolaToken), address(0), address(autoDolaVault), address(mainRewarder));

        vm.expectRevert("AutoDolaVault: autoDOLA vault cannot be zero address");
        new AutoDolaVault(owner, address(dolaToken), address(tokeToken), address(0), address(mainRewarder));

        vm.expectRevert("AutoDolaVault: MainRewarder cannot be zero address");
        new AutoDolaVault(owner, address(dolaToken), address(tokeToken), address(autoDolaVault), address(0));

        // Test successful construction
        assertTrue(address(vault.dolaToken()) == address(dolaToken));
        assertTrue(address(vault.tokeToken()) == address(tokeToken));
        assertTrue(address(vault.autoDolaVault()) == address(autoDolaVault));
        assertTrue(address(vault.mainRewarder()) == address(mainRewarder));
    }

    function testDeposit() public {
        uint256 depositAmount = 1000e18; // 1000 DOLA

        // Approve vault to spend DOLA
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);

        // Get initial balances
        uint256 initialClientDola = dolaToken.balanceOf(client1);
        uint256 initialVaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 initialStakedShares = mainRewarder.balanceOf(address(vault));

        // Perform deposit
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Verify DOLA transferred from client
        assertEq(dolaToken.balanceOf(client1), initialClientDola - depositAmount);

        // Verify autoDOLA shares received and staked
        uint256 finalVaultShares = autoDolaVault.balanceOf(address(vault));
        uint256 finalStakedShares = mainRewarder.balanceOf(address(vault));

        assertTrue(finalVaultShares > initialVaultShares);
        assertTrue(finalStakedShares > initialStakedShares);

        // Verify user balance is tracked
        assertEq(vault.balanceOf(address(dolaToken), user1), depositAmount);

        // Verify total deposited is updated
        assertEq(vault.getTotalDeposited(address(dolaToken)), depositAmount);
    }

    function testDepositRequirements() public {
        uint256 depositAmount = 1000e18;

        // Test unauthorized client
        vm.expectRevert("Vault: unauthorized, only authorized clients");
        vm.prank(address(0x9999));
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Test wrong token
        vm.expectRevert("AutoDolaVault: only DOLA token supported");
        vm.prank(client1);
        vault.deposit(address(tokeToken), depositAmount, user1);

        // Test zero amount
        vm.expectRevert("AutoDolaVault: amount must be greater than zero");
        vm.prank(client1);
        vault.deposit(address(dolaToken), 0, user1);

        // Test zero recipient
        vm.expectRevert("AutoDolaVault: recipient cannot be zero address");
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, address(0));
    }

    function testWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;

        // First deposit - client1 deposits for client1 (themselves)
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, client1);

        // Get initial balances
        uint256 initialUserBalance = vault.balanceOf(address(dolaToken), client1);
        uint256 initialRecipientDola = dolaToken.balanceOf(user2);

        // Perform withdrawal - client1 withdraws their own balance
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, user2);

        // Verify balances
        uint256 finalUserBalance = vault.balanceOf(address(dolaToken), client1);
        uint256 finalRecipientDola = dolaToken.balanceOf(user2);

        assertEq(finalUserBalance, initialUserBalance - withdrawAmount);
        assertEq(finalRecipientDola, initialRecipientDola + withdrawAmount);
    }

    function testWithdrawRequirements() public {
        uint256 withdrawAmount = 1000e18;

        // Test unauthorized client
        vm.expectRevert("Vault: unauthorized, only authorized clients");
        vm.prank(address(0x9999));
        vault.withdraw(address(dolaToken), withdrawAmount, user1);

        // Test wrong token
        vm.expectRevert("AutoDolaVault: only DOLA token supported");
        vm.prank(client1);
        vault.withdraw(address(tokeToken), withdrawAmount, user1);

        // Test zero amount
        vm.expectRevert("AutoDolaVault: amount must be greater than zero");
        vm.prank(client1);
        vault.withdraw(address(dolaToken), 0, user1);

        // Test zero recipient
        vm.expectRevert("AutoDolaVault: recipient cannot be zero address");
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, address(0));

        // Test insufficient balance
        vm.expectRevert("AutoDolaVault: insufficient balance");
        vm.prank(client1);
        vault.withdraw(address(dolaToken), withdrawAmount, user1);
    }

    function testYieldCalculation() public {
        uint256 depositAmount = 1000e18;

        // Deposit
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Initial balance should equal deposit
        assertEq(vault.balanceOf(address(dolaToken), user1), depositAmount);

        // Simulate yield growth in autoDOLA
        uint256 yieldAmount = 100e18; // 10% yield
        autoDolaVault.simulateYield(yieldAmount);

        // Balance should now reflect yield
        uint256 balanceWithYield = vault.balanceOf(address(dolaToken), user1);
        assertTrue(balanceWithYield > depositAmount);
    }

    function testTokeRewardsClaim() public {
        uint256 depositAmount = 1000e18;
        uint256 rewardAmount = 50e18;

        // Deposit to enable staking
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Simulate earning TOKE rewards
        mainRewarder.simulateRewards(address(vault), rewardAmount);

        // Verify rewards are available
        assertEq(vault.getTokeRewards(), rewardAmount);

        // Only owner can claim
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", client1));
        vm.prank(client1);
        vault.claimTokeRewards(user1);

        // Owner claims rewards
        uint256 initialTokeBalance = tokeToken.balanceOf(user1);
        vm.prank(owner);
        vault.claimTokeRewards(user1);

        // Verify rewards transferred
        assertEq(tokeToken.balanceOf(user1), initialTokeBalance + rewardAmount);
        assertEq(vault.getTokeRewards(), 0);
    }

    function testEmergencyWithdraw() public {
        uint256 depositAmount = 1000e18;
        uint256 emergencyAmount = 500e18;

        // Deposit first
        vm.prank(client1);
        dolaToken.approve(address(vault), depositAmount);
        vm.prank(client1);
        vault.deposit(address(dolaToken), depositAmount, user1);

        // Only owner can emergency withdraw
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", client1));
        vm.prank(client1);
        vault.emergencyWithdraw(emergencyAmount);

        // Owner performs emergency withdraw
        uint256 initialOwnerDola = dolaToken.balanceOf(owner);
        vm.prank(owner);
        vault.emergencyWithdraw(emergencyAmount);

        // Verify withdrawal
        uint256 finalOwnerDola = dolaToken.balanceOf(owner);
        assertTrue(finalOwnerDola >= initialOwnerDola + emergencyAmount);
    }

    function testMultipleClients() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;

        // Client 1 deposits
        vm.prank(client1);
        dolaToken.approve(address(vault), deposit1);
        vm.prank(client1);
        vault.deposit(address(dolaToken), deposit1, user1);

        // Client 2 deposits
        vm.prank(client2);
        dolaToken.approve(address(vault), deposit2);
        vm.prank(client2);
        vault.deposit(address(dolaToken), deposit2, user2);

        // Verify individual balances
        assertEq(vault.balanceOf(address(dolaToken), user1), deposit1);
        assertEq(vault.balanceOf(address(dolaToken), user2), deposit2);

        // Verify total deposited
        assertEq(vault.getTotalDeposited(address(dolaToken)), deposit1 + deposit2);

        // Simulate yield
        autoDolaVault.simulateYield(300e18); // 10% total yield

        // Both users should benefit proportionally from yield
        uint256 balance1WithYield = vault.balanceOf(address(dolaToken), user1);
        uint256 balance2WithYield = vault.balanceOf(address(dolaToken), user2);

        assertTrue(balance1WithYield > deposit1);
        assertTrue(balance2WithYield > deposit2);

        // Verify proportional yield distribution
        uint256 totalYield = (balance1WithYield + balance2WithYield) - (deposit1 + deposit2);
        uint256 expectedYield1 = (totalYield * deposit1) / (deposit1 + deposit2);
        uint256 actualYield1 = balance1WithYield - deposit1;

        // Allow for small rounding differences
        assertTrue(actualYield1 >= expectedYield1 - 1e15 && actualYield1 <= expectedYield1 + 1e15);
    }

    function testZeroBalanceQueries() public {
        // Test balance queries for non-existent deposits
        assertEq(vault.balanceOf(address(dolaToken), user1), 0);
        assertEq(vault.getTotalDeposited(address(dolaToken)), 0);
        assertEq(vault.getTotalShares(), 0);
        assertEq(vault.getTokeRewards(), 0);
    }

    function testOnlyDolaTokenSupported() public {
        // Create another ERC20 token
        MockERC20 otherToken = new MockERC20("OTHER", "OTHER", 18);

        // Verify balance query rejects non-DOLA tokens
        vm.expectRevert("AutoDolaVault: only DOLA token supported");
        vault.balanceOf(address(otherToken), user1);
    }
}