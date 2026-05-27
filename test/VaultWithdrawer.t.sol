// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "./mocks/MockERC4626Vault.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title VaultWithdrawerTest
 * @notice Comprehensive tests for vault withdrawer authorization and skimSurplus functionality
 */
contract VaultWithdrawerTest is Test {
    using SafeERC20 for IERC20;

    ERC4626YieldStrategy public vault;
    MockERC20 public depositToken;
    MockERC4626Vault public erc4626Vault;

    address public owner;
    address public client;
    address public withdrawer;
    address public recipient;
    address public unauthorized;

    event WithdrawerAuthorizationSet(address indexed withdrawer, bool authorized);
    event SurplusSkimmed(
        address indexed token, address indexed client, address indexed withdrawer, uint256 amount, address recipient
    );

    function setUp() public {
        owner = address(this);
        client = address(0x1);
        withdrawer = address(0x2);
        recipient = address(0x3);
        unauthorized = address(0x4);

        // Deploy mock tokens
        depositToken = new MockERC20("DOLA", "DOLA", 18);

        // Deploy mock ERC4626 vault
        erc4626Vault = new MockERC4626Vault("Vault Shares", "vDOLA", address(depositToken));

        // Deploy the real ERC4626YieldStrategy
        vault = new ERC4626YieldStrategy(owner, address(depositToken), address(erc4626Vault));

        // Authorize client for vault operations
        vault.setClient(client, true);

        // Mint tokens to client for testing
        depositToken.mint(client, 10000000e18);
    }

    /**
     * @notice Helper function to set up principal and surplus for a client
     * @param token The token address (must be depositToken)
     * @param account The client account
     * @param principal The principal amount to deposit
     * @param surplus The surplus amount to simulate (via yield in erc4626Vault)
     */
    function setupPrincipalAndSurplus(address token, address account, uint256 principal, uint256 surplus) internal {
        // Mint tokens to account if needed (checking balance to avoid double-minting)
        if (depositToken.balanceOf(account) < principal) {
            depositToken.mint(account, principal);
        }

        vm.startPrank(account);
        depositToken.approve(address(vault), principal);
        vault.deposit(token, principal, account);
        vm.stopPrank();

        if (surplus > 0) {
            erc4626Vault.simulateYield(surplus);
        }
    }

    // ============ AUTHORIZATION TESTS ============

    function testSetWithdrawerAuthorization() public {
        // Should emit event when authorizing
        vm.expectEmit(true, false, false, true);
        emit WithdrawerAuthorizationSet(withdrawer, true);

        vault.setWithdrawer(withdrawer, true);

        assertTrue(vault.authorizedWithdrawers(withdrawer));
    }

    function testSetWithdrawerDeauthorization() public {
        // First authorize
        vault.setWithdrawer(withdrawer, true);
        assertTrue(vault.authorizedWithdrawers(withdrawer));

        // Then deauthorize
        vm.expectEmit(true, false, false, true);
        emit WithdrawerAuthorizationSet(withdrawer, false);

        vault.setWithdrawer(withdrawer, false);

        assertFalse(vault.authorizedWithdrawers(withdrawer));
    }

    function testSetWithdrawerOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.setWithdrawer(withdrawer, true);
    }

    function testSetWithdrawerZeroAddress() public {
        vm.expectRevert("AYieldStrategy: withdrawer cannot be zero address");
        vault.setWithdrawer(address(0), true);
    }

    function testSetWithdrawerMultiple() public {
        address withdrawer2 = address(0x5);

        vault.setWithdrawer(withdrawer, true);
        vault.setWithdrawer(withdrawer2, true);

        assertTrue(vault.authorizedWithdrawers(withdrawer));
        assertTrue(vault.authorizedWithdrawers(withdrawer2));
    }

    // ============ skimSurplus FUNCTIONALITY TESTS ============
    // New model: skimSurplus(token, recipient) always skims the FULL surplus of EVERY
    // currently-authorized client in a single redeem. No caller-supplied client/amount.

    function testSkimSurplusSuccess() public {
        // Setup: authorize withdrawer and give client a balance with surplus
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 100e18);

        uint256 surplus =
            vault.totalBalanceOf(address(depositToken), client) - vault.principalOf(address(depositToken), client);
        uint256 recipientBalanceBefore = depositToken.balanceOf(recipient);

        // Execute skim — emits one SurplusSkimmed for the (only) surplus-bearing client
        vm.expectEmit(true, true, true, true);
        emit SurplusSkimmed(address(depositToken), client, withdrawer, surplus, recipient);

        vm.prank(withdrawer);
        uint256 returned = vault.skimSurplus(address(depositToken), recipient);

        // Return value == actual underlying delivered to recipient (balance delta)
        assertEq(returned, depositToken.balanceOf(recipient) - recipientBalanceBefore, "return == underlying delivered");
        // Principal unchanged at 1000e18; full surplus (~100e18) sent to recipient
        assertEq(vault.balanceOf(address(depositToken), client), 1000e18);
        assertApproxEqAbs(
            depositToken.balanceOf(recipient), recipientBalanceBefore + surplus, 1, "Recipient gets full surplus"
        );
        // After skimming all surplus, total balance ~= principal
        assertApproxEqAbs(vault.totalBalanceOf(address(depositToken), client), 1000e18, 2);
    }

    function testSkimSurplusAllAuthorizedClients() public {
        address client2 = address(0x6);

        vault.setWithdrawer(withdrawer, true);
        vault.setClient(client2, true); // Authorize client2

        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 100e18);
        setupPrincipalAndSurplus(address(depositToken), client2, 2000e18, 400e18);

        // ONE call skims BOTH clients in a single redeem
        uint256 redeemsBefore = erc4626Vault.redeemCount();
        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient);
        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 1, "exactly one redeem for all clients");

        // Both principals untouched
        assertEq(vault.balanceOf(address(depositToken), client), 1000e18);
        assertEq(vault.balanceOf(address(depositToken), client2), 2000e18);

        // Both clients' surplus skimmed -> totals back to principal
        assertApproxEqAbs(vault.totalBalanceOf(address(depositToken), client), 1000e18, 2);
        assertApproxEqAbs(vault.totalBalanceOf(address(depositToken), client2), 2000e18, 2);
    }

    function testSkimSurplusSingleClientFullSurplus() public {
        // Only one authorized client (length-1 set is just the array-length-1 case)
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 1000e18);

        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient);

        // Principal stays at 1000e18, full surplus skimmed -> total ~= principal
        assertEq(vault.balanceOf(address(depositToken), client), 1000e18);
        assertApproxEqAbs(vault.totalBalanceOf(address(depositToken), client), 1000e18, 2);
    }

    function testSkimSurplusPrincipalUntouched() public {
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 500e18);

        uint256 totalDepositedBefore = vault.getTotalDeposited(address(depositToken));

        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient);

        assertEq(vault.principalOf(address(depositToken), client), 1000e18);
        assertEq(vault.getTotalDeposited(address(depositToken)), totalDepositedBefore);
    }

    function testSkimSurplusExcludesDeauthorizedClient() public {
        address client2 = address(0x6);

        vault.setWithdrawer(withdrawer, true);
        vault.setClient(client2, true);

        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 100e18);
        setupPrincipalAndSurplus(address(depositToken), client2, 1000e18, 100e18);

        // De-authorize client2 — it is no longer in the skim set
        vault.setClient(client2, false);

        // Only client's surplus is emitted/skimmed; client2 is excluded
        uint256 surplus1 =
            vault.totalBalanceOf(address(depositToken), client) - vault.principalOf(address(depositToken), client);

        vm.expectEmit(true, true, true, true);
        emit SurplusSkimmed(address(depositToken), client, withdrawer, surplus1, recipient);

        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient);

        // client2's principal and surplus remain in the strategy (recoverable via totalWithdrawal)
        assertEq(vault.principalOf(address(depositToken), client2), 1000e18);
        assertGt(vault.totalBalanceOf(address(depositToken), client2), 1000e18);
    }

    function testSkimSurplusIncludesNewlyAuthorizedClient() public {
        address client2 = address(0x6);

        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 100e18);

        // Authorize client2 AFTER client, then give it principal + surplus
        vault.setClient(client2, true);
        setupPrincipalAndSurplus(address(depositToken), client2, 1000e18, 100e18);

        uint256 redeemsBefore = erc4626Vault.redeemCount();
        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient);

        // Single redeem covers both, including the newly-authorized client2
        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 1, "one redeem for both clients");
        assertApproxEqAbs(vault.totalBalanceOf(address(depositToken), client2), 1000e18, 2);
    }

    function testSkimSurplusEmptyClientSetIsNoOp() public {
        // Fresh strategy with NO authorized clients
        ERC4626YieldStrategy emptyVault = new ERC4626YieldStrategy(owner, address(depositToken), address(erc4626Vault));
        emptyVault.setWithdrawer(withdrawer, true);

        uint256 redeemsBefore = erc4626Vault.redeemCount();

        // Must NOT revert despite empty client set
        vm.prank(withdrawer);
        emptyVault.skimSurplus(address(depositToken), recipient);

        // No-op: no redeem performed
        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 0, "empty client set => no redeem");
    }

    function testSkimSurplusNoSurplusIsNoOp() public {
        // Authorized client with principal but zero yield
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 0);

        uint256 redeemsBefore = erc4626Vault.redeemCount();

        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient);

        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 0, "no surplus => no redeem");
        assertEq(vault.principalOf(address(depositToken), client), 1000e18);
    }

    // ============ M-01 REGRESSION TEST ============

    /// @notice Calling setClient(c, true) twice must NOT cause a 2x over-skim.
    ///         The EnumerableSet dedupes, so the client appears exactly once in the skim set.
    function testSkimSurplusIdempotentSetNoOverSkim() public {
        vault.setWithdrawer(withdrawer, true);

        // Authorize the same client twice (idempotent on the set)
        vault.setClient(client, true);
        vault.setClient(client, true);

        // The set contains the client exactly once
        assertEq(vault.authorizedClientCount(), 1, "duplicate setClient does not grow the set");
        address[] memory clients = vault.getAuthorizedClients();
        assertEq(clients.length, 1, "set has one distinct client");
        assertEq(clients[0], client);

        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 200e18);

        uint256 trueSurplus =
            vault.totalBalanceOf(address(depositToken), client) - vault.principalOf(address(depositToken), client);
        uint256 recipientBefore = depositToken.balanceOf(recipient);

        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient);

        uint256 received = depositToken.balanceOf(recipient) - recipientBefore;

        // Skimmed amount ~= true aggregate surplus, NOT 2x (would be ~400e18 if duplicated)
        assertApproxEqAbs(received, trueSurplus, 2, "skim equals true surplus, not 2x");
        assertLe(received, trueSurplus + 1, "never exceeds true surplus");

        // Principal still fully backed: held-share value >= recorded principal (no under-backing)
        uint256 heldShares = erc4626Vault.balanceOf(address(vault));
        uint256 heldValue = erc4626Vault.convertToAssets(heldShares);
        assertGe(heldValue, vault.principalOf(address(depositToken), client), "principal still backed");
    }

    // ============ SECURITY / GUARD TESTS ============

    function testSkimSurplusUnauthorizedReverts() public {
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 0);

        vm.prank(unauthorized);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized withdrawers");
        vault.skimSurplus(address(depositToken), recipient);
    }

    function testSkimSurplusAfterDeauthorizationReverts() public {
        // Authorize then deauthorize the withdrawer
        vault.setWithdrawer(withdrawer, true);
        vault.setWithdrawer(withdrawer, false);

        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 0);

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized withdrawers");
        vault.skimSurplus(address(depositToken), recipient);
    }

    function testSkimSurplusZeroToken() public {
        vault.setWithdrawer(withdrawer, true);

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: token cannot be zero address");
        vault.skimSurplus(address(0), recipient);
    }

    function testSkimSurplusZeroRecipient() public {
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 0);

        vm.prank(withdrawer);
        vm.expectRevert("AYieldStrategy: recipient cannot be zero address");
        vault.skimSurplus(address(depositToken), address(0));
    }

    function testSkimSurplusNonOwnerCannotAuthorize() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        vault.setWithdrawer(withdrawer, true);

        assertFalse(vault.authorizedWithdrawers(withdrawer));
    }

    function testSkimSurplusReentrancyProtection() public {
        // The nonReentrant modifier should prevent reentrancy. Verify a normal call completes.
        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 100e18);

        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient);

        assertEq(vault.balanceOf(address(depositToken), client), 1000e18);
    }

    // ============ EDGE CASE TESTS ============

    function testSkimSurplusDifferentRecipients() public {
        address recipient2 = address(0x7);

        vault.setWithdrawer(withdrawer, true);
        setupPrincipalAndSurplus(address(depositToken), client, 1000e18, 300e18);

        // First skim sends full surplus to recipient
        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient);
        assertApproxEqAbs(depositToken.balanceOf(recipient), 300e18, 2, "Recipient 1 gets full surplus");

        // After the first skim there is no surplus left; a second skim to recipient2 is a no-op
        uint256 redeemsBefore = erc4626Vault.redeemCount();
        vm.prank(withdrawer);
        vault.skimSurplus(address(depositToken), recipient2);
        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 0, "no surplus left => no-op");
        assertEq(depositToken.balanceOf(recipient2), 0, "Recipient 2 gets nothing");
    }

    // ============ AUTHORIZATION CHANGE TESTS ============

    function testAuthorizationToggle() public {
        // Authorize
        vault.setWithdrawer(withdrawer, true);
        assertTrue(vault.authorizedWithdrawers(withdrawer));

        // Deauthorize
        vault.setWithdrawer(withdrawer, false);
        assertFalse(vault.authorizedWithdrawers(withdrawer));

        // Re-authorize
        vault.setWithdrawer(withdrawer, true);
        assertTrue(vault.authorizedWithdrawers(withdrawer));
    }

    function testMultipleWithdrawersIndependentAuthorization() public {
        address withdrawer2 = address(0x8);

        vault.setWithdrawer(withdrawer, true);
        vault.setWithdrawer(withdrawer2, true);

        // Deauthorize only one
        vault.setWithdrawer(withdrawer, false);

        assertFalse(vault.authorizedWithdrawers(withdrawer));
        assertTrue(vault.authorizedWithdrawers(withdrawer2));
    }
}
