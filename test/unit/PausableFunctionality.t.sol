// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/AutoPoolYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "../mocks/MockAutoPool.sol";
import "../../src/mocks/MockMainRewarder.sol";

/**
 * @title PausableFunctionalityTest
 * @notice Unit tests for IPausable implementation in AYieldStrategy and AutoPoolYieldStrategy
 */
contract PausableFunctionalityTest is Test {
    AutoPoolYieldStrategy vault;
    MockERC20 underlyingToken;
    MockERC20 tokeToken;
    MockAutoPool autoPoolVault;
    MockMainRewarder mainRewarder;

    address owner = address(0x1234);
    address pauser = address(0x5678);
    address client = address(0x9ABC);
    address user = address(0xDEF0);
    address withdrawer = address(0x1357);
    address randomUser = address(0x2468);

    uint256 constant INITIAL_TOKEN_SUPPLY = 10000000e18;
    uint256 constant INITIAL_TOKE_SUPPLY = 1000000e18;

    function setUp() public {
        // Deploy mock tokens
        underlyingToken = new MockERC20("Underlying", "UNDERLYING", 18);
        tokeToken = new MockERC20("TOKE", "TOKE", 18);

        // Deploy mock MainRewarder
        mainRewarder = new MockMainRewarder(address(tokeToken));

        // Deploy mock autoPool vault
        autoPoolVault = new MockAutoPool("AutoPool", "autoPool", address(underlyingToken), address(mainRewarder));

        // Deploy the vault
        vm.prank(owner);
        vault = new AutoPoolYieldStrategy(
            owner, address(underlyingToken), address(tokeToken), address(autoPoolVault), address(mainRewarder)
        );

        // Mint tokens
        underlyingToken.mint(client, INITIAL_TOKEN_SUPPLY);
        underlyingToken.mint(address(autoPoolVault), INITIAL_TOKEN_SUPPLY);
        tokeToken.mint(address(mainRewarder), INITIAL_TOKE_SUPPLY);

        // Authorize client and withdrawer
        vm.startPrank(owner);
        vault.setClient(client, true);
        vault.setWithdrawer(withdrawer, true);
        vault.setPauser(pauser);
        vm.stopPrank();

        // Approve vault to spend client's underlying tokens
        vm.prank(client);
        underlyingToken.approve(address(vault), type(uint256).max);
    }

    // ============ setPauser() TESTS ============

    function testSetPauserByOwner() public {
        address newPauser = address(0xAAAA);

        vm.expectEmit(true, true, false, false);
        emit PauserSet(pauser, newPauser);

        vm.prank(owner);
        vault.setPauser(newPauser);

        assertEq(vault.pauser(), newPauser);
    }

    function testSetPauserToZeroAddress() public {
        // Setting to zero address should work (effectively disabling pausing)
        vm.prank(owner);
        vault.setPauser(address(0));

        assertEq(vault.pauser(), address(0));
    }

    function testSetPauserRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        vault.setPauser(address(0xBBBB));
    }

    function testSetPauserEmitsPauserSetEvent() public {
        address newPauser = address(0xCCCC);

        vm.expectEmit(true, true, false, false);
        emit PauserSet(pauser, newPauser);

        vm.prank(owner);
        vault.setPauser(newPauser);
    }

    // ============ pauser() GETTER TESTS ============

    function testPauserReturnsCorrectAddress() public view {
        assertEq(vault.pauser(), pauser);
    }

    function testPauserReturnsZeroIfNotSet() public {
        // Deploy new vault without setting pauser
        vm.prank(owner);
        AutoPoolYieldStrategy newVault = new AutoPoolYieldStrategy(
            owner, address(underlyingToken), address(tokeToken), address(autoPoolVault), address(mainRewarder)
        );

        assertEq(newVault.pauser(), address(0));
    }

    // ============ pause() TESTS ============

    function testPauseByPauser() public {
        assertFalse(vault.paused());

        vm.prank(pauser);
        vault.pause();

        assertTrue(vault.paused());
    }

    function testPauseRevertsForOwner() public {
        vm.expectRevert("AYieldStrategy: caller is not the pauser");
        vm.prank(owner);
        vault.pause();
    }

    function testPauseRevertsForRandomUser() public {
        vm.expectRevert("AYieldStrategy: caller is not the pauser");
        vm.prank(randomUser);
        vault.pause();
    }

    function testPauseRevertsWhenAlreadyPaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(pauser);
        vault.pause();
    }

    function testPauseRevertsWhenPauserIsZero() public {
        // Set pauser to zero
        vm.prank(owner);
        vault.setPauser(address(0));

        // Now no one can pause
        vm.expectRevert("AYieldStrategy: caller is not the pauser");
        vm.prank(pauser);
        vault.pause();
    }

    // ============ unpause() TESTS ============

    function testUnpauseByPauser() public {
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(pauser);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function testUnpauseByOwner() public {
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function testUnpauseRevertsForRandomUser() public {
        vm.prank(pauser);
        vault.pause();

        vm.expectRevert("AYieldStrategy: caller is not the owner or pauser");
        vm.prank(randomUser);
        vault.unpause();
    }

    function testUnpauseRevertsWhenNotPaused() public {
        vm.expectRevert(abi.encodeWithSignature("ExpectedPause()"));
        vm.prank(pauser);
        vault.unpause();
    }

    // ============ whenNotPaused MODIFIER TESTS - deposit() ============

    function testDepositWhenNotPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, user);

        assertEq(vault.principalOf(address(underlyingToken), user), depositAmount);
    }

    function testDepositRevertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(client);
        vault.deposit(address(underlyingToken), 1000e18, user);
    }

    function testDepositWorksAfterUnpause() public {
        uint256 depositAmount = 1000e18;

        // Pause
        vm.prank(pauser);
        vault.pause();

        // Unpause
        vm.prank(owner);
        vault.unpause();

        // Deposit should work
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, user);

        assertEq(vault.principalOf(address(underlyingToken), user), depositAmount);
    }

    // ============ whenNotPaused MODIFIER TESTS - withdraw() ============

    function testWithdrawWhenNotPaused() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 500e18;

        // Setup: deposit first
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, client);

        // Withdraw should work
        vm.prank(client);
        vault.withdraw(address(underlyingToken), withdrawAmount, client);

        assertEq(vault.principalOf(address(underlyingToken), client), depositAmount - withdrawAmount);
    }

    function testWithdrawRevertsWhenPaused() public {
        uint256 depositAmount = 1000e18;

        // Setup: deposit first
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, client);

        // Pause
        vm.prank(pauser);
        vault.pause();

        // Withdraw should revert
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(client);
        vault.withdraw(address(underlyingToken), 500e18, client);
    }

    // ============ whenNotPaused MODIFIER TESTS - withdrawFrom() ============

    function testWithdrawFromWhenNotPaused() public {
        uint256 depositAmount = 10000e18;

        // Setup: deposit first
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, client);

        // Generate yield
        autoPoolVault.simulateYield(1000e18);

        // WithdrawFrom should work
        vm.prank(withdrawer);
        vault.withdrawFrom(address(underlyingToken), client, 500e18, withdrawer);
    }

    function testWithdrawFromRevertsWhenPaused() public {
        uint256 depositAmount = 10000e18;

        // Setup: deposit first
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, client);

        // Generate yield
        autoPoolVault.simulateYield(1000e18);

        // Pause
        vm.prank(pauser);
        vault.pause();

        // WithdrawFrom should revert
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(withdrawer);
        vault.withdrawFrom(address(underlyingToken), client, 500e18, withdrawer);
    }

    // ============ whenNotPaused MODIFIER TESTS - totalWithdrawal() ============

    function testTotalWithdrawalRevertsWhenPaused() public {
        uint256 depositAmount = 1000e18;

        // Setup: deposit first
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, client);

        // Pause
        vm.prank(pauser);
        vault.pause();

        // TotalWithdrawal should revert
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(owner);
        vault.totalWithdrawal(address(underlyingToken), client);
    }

    function testTotalWithdrawalWorksWhenNotPaused() public {
        uint256 depositAmount = 1000e18;

        // Setup: deposit first
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, client);

        // Should work when not paused (initiates phase 1)
        vm.prank(owner);
        vault.totalWithdrawal(address(underlyingToken), client);
    }

    // ============ whenNotPaused MODIFIER TESTS - claimTokeRewards() ============

    function testClaimTokeRewardsRevertsWhenPaused() public {
        // Pause
        vm.prank(pauser);
        vault.pause();

        // ClaimTokeRewards should revert
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(owner);
        vault.claimTokeRewards(owner);
    }

    function testClaimTokeRewardsWorksWhenNotPaused() public {
        uint256 depositAmount = 1000e18;

        // Setup: deposit first
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, client);

        // Should work when not paused
        vm.prank(owner);
        vault.claimTokeRewards(owner);
    }

    // ============ emergencyWithdraw TESTS (should work when paused) ============

    function testEmergencyWithdrawWorksWhenPaused() public {
        uint256 depositAmount = 1000e18;

        // Setup: deposit first
        vm.prank(client);
        vault.deposit(address(underlyingToken), depositAmount, client);

        // Pause
        vm.prank(pauser);
        vault.pause();

        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);

        // Emergency withdraw should still work when paused
        vm.prank(owner);
        vault.emergencyWithdraw(500e18);

        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        assertTrue(ownerBalanceAfter > ownerBalanceBefore);
    }

    // ============ IPausable INTERFACE COMPLIANCE TESTS ============

    function testImplementsIPausable() public view {
        // Verify all IPausable functions are available
        vault.pauser();
        // pause() and unpause() are tested elsewhere
        // This test just verifies the interface is implemented
    }

    function testPausedStateIsAccessible() public view {
        // The paused() function from OpenZeppelin Pausable should be accessible
        assertFalse(vault.paused());
    }

    // ============ EVENTS ============

    event PauserSet(address indexed oldPauser, address indexed newPauser);
}
