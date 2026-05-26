// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "../mocks/MockERC4626Vault.sol";
import "../mocks/MockAMMAdapter.sol";

/**
 * @title ERC4626MarketYieldStrategyTest
 * @notice Comprehensive unit tests for ERC4626MarketYieldStrategy
 * @dev Covers deposit/withdraw via AMM, slippage tolerance, principal tracking, yield distribution,
 *      access control, pause behavior, emergency withdraw, totalWithdrawal two-phase, and surplus extraction.
 */
contract ERC4626MarketYieldStrategyTest is Test {
    ERC4626MarketYieldStrategy strategy;
    MockERC20 underlyingToken;
    MockERC4626Vault erc4626Vault;
    MockAMMAdapter ammAdapter;

    address owner = address(0x1234);
    address client = address(0x5678);
    address pauser = address(0x9ABC);
    address user1 = address(0xDEF0);
    address user2 = address(0x1357);
    address user3 = address(0x2468);
    address withdrawer = address(0xABCD);
    address randomUser = address(0xBEEF);

    uint256 constant INITIAL_TOKEN_SUPPLY = 10_000_000e18;

    function setUp() public {
        // Deploy mock tokens
        underlyingToken = new MockERC20("Underlying", "UNDERLYING", 18);

        // Deploy mock ERC4626 vault
        erc4626Vault = new MockERC4626Vault("Vault Shares", "vUNDERLYING", address(underlyingToken));

        // Deploy mock AMM adapter
        ammAdapter = new MockAMMAdapter();

        // Deploy the strategy
        vm.prank(owner);
        strategy =
            new ERC4626MarketYieldStrategy(owner, address(underlyingToken), address(erc4626Vault), address(ammAdapter));

        // Set 1:1 exchange rates for underlying <-> vault tokens
        ammAdapter.setExchangeRate(address(underlyingToken), address(erc4626Vault), 1e18);
        ammAdapter.setExchangeRate(address(erc4626Vault), address(underlyingToken), 1e18);

        // Mint tokens
        underlyingToken.mint(client, INITIAL_TOKEN_SUPPLY);
        underlyingToken.mint(owner, INITIAL_TOKEN_SUPPLY);

        // Mint vault shares to AMM adapter as reserves (for deposit swaps)
        // When someone deposits underlying, AMM gives them vault shares
        // We need the vault to have shares that can be sent by the AMM
        // Since vault shares are minted via vault.deposit, let's do that approach:
        // Fund AMM with vault shares by depositing underlying into vault on behalf of AMM
        underlyingToken.mint(address(this), INITIAL_TOKEN_SUPPLY);
        underlyingToken.approve(address(erc4626Vault), INITIAL_TOKEN_SUPPLY);
        erc4626Vault.deposit(INITIAL_TOKEN_SUPPLY, address(ammAdapter));

        // Also fund AMM with underlying tokens for withdrawal swaps
        underlyingToken.mint(address(ammAdapter), INITIAL_TOKEN_SUPPLY);

        // Authorize client, withdrawer, pauser
        vm.startPrank(owner);
        strategy.setClient(client, true);
        strategy.setWithdrawer(withdrawer, true);
        strategy.setPauser(pauser);
        strategy.setSlippageTolerance(100); // 1% default slippage
        vm.stopPrank();

        // Approve strategy to spend client's tokens
        vm.prank(client);
        underlyingToken.approve(address(strategy), type(uint256).max);

        // Approve strategy to spend owner's tokens (for depositAsOwner)
        vm.prank(owner);
        underlyingToken.approve(address(strategy), type(uint256).max);
    }

    // ============ DEPOSIT VIA AMM TESTS ============

    /// @notice Test single-user deposit via AMM swap and verify principal tracking
    function testSingleUserDeposit() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), depositAmount);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), depositAmount);
        assertGt(strategy.getTotalShares(), 0);
    }

    /// @notice Test multi-user deposits via AMM and verify independent principal tracking
    function testMultiUserDeposits() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;
        uint256 deposit3 = 3000e18;

        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), deposit1, user1);
        strategy.deposit(address(underlyingToken), deposit2, user2);
        strategy.deposit(address(underlyingToken), deposit3, user3);
        vm.stopPrank();

        assertEq(strategy.principalOf(address(underlyingToken), user1), deposit1);
        assertEq(strategy.principalOf(address(underlyingToken), user2), deposit2);
        assertEq(strategy.principalOf(address(underlyingToken), user3), deposit3);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), deposit1 + deposit2 + deposit3);
    }

    /// @notice Test deposit transfers underlying tokens from depositor and receives vault shares
    function testDepositTransfersTokensCorrectly() public {
        uint256 depositAmount = 1000e18;
        uint256 clientBalanceBefore = underlyingToken.balanceOf(client);

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        uint256 clientBalanceAfter = underlyingToken.balanceOf(client);
        assertEq(clientBalanceBefore - clientBalanceAfter, depositAmount);

        // Strategy should hold vault shares
        assertGt(strategy.getTotalShares(), 0);
    }

    // ============ WITHDRAW VIA AMM TESTS ============

    /// @notice Test withdraw via AMM swap returns correct amount and updates principal
    function testWithdrawUpdatesCorrectly() public {
        uint256 depositAmount = 1000e18;
        uint256 withdrawAmount = 400e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        uint256 balanceBefore = underlyingToken.balanceOf(client);

        vm.prank(client);
        strategy.withdraw(address(underlyingToken), withdrawAmount, client);

        uint256 balanceAfter = underlyingToken.balanceOf(client);

        // Principal should decrease by requested amount
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount - withdrawAmount);
        // Client should have received tokens
        assertApproxEqAbs(balanceAfter - balanceBefore, withdrawAmount, 1);
    }

    /// @notice Test withdrawal capped to available principal (dust handling)
    function testWithdrawalCappedToPrincipal() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Attempt to withdraw more than deposited
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), depositAmount + 500e18, client);

        // Principal should be zero (capped to available)
        assertEq(strategy.principalOf(address(underlyingToken), client), 0);
    }

    // ============ SLIPPAGE TOLERANCE TESTS ============

    /// @notice Test setSlippageTolerance only callable by owner
    function testSetSlippageToleranceOnlyOwner() public {
        vm.prank(owner);
        strategy.setSlippageTolerance(50);
        assertEq(strategy.slippageToleranceBps(), 50);
    }

    /// @notice Test setSlippageTolerance reverts for non-owner
    function testSetSlippageToleranceRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        strategy.setSlippageTolerance(50);
    }

    /// @notice Test setSlippageTolerance reverts when exceeding MAX_BPS
    function testSetSlippageToleranceRevertsExceedingMaxBps() public {
        vm.expectRevert("ERC4626MarketYieldStrategy: slippage tolerance exceeds MAX_BPS");
        vm.prank(owner);
        strategy.setSlippageTolerance(10001);
    }

    /// @notice Test deposit reverts when AMM output is below slippage-adjusted minimum
    function testDepositRevertsOnSlippage() public {
        // Set exchange rate that gives back less than acceptable
        // With 1% slippage tolerance, if vault says 1000 shares ideal,
        // min is 990 shares. Set AMM rate to give only 980 (98% = 0.98e18)
        ammAdapter.setExchangeRate(address(underlyingToken), address(erc4626Vault), 0.98e18);

        vm.prank(owner);
        strategy.setSlippageTolerance(10); // 0.1% tolerance — very tight

        vm.expectRevert("MockAMMAdapter: insufficient output amount");
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test withdraw reverts when AMM output is below slippage-adjusted minimum
    function testWithdrawRevertsOnSlippage() public {
        // First deposit at 1:1 rate
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, client);

        // Now set withdrawal rate that gives much less
        ammAdapter.setExchangeRate(address(erc4626Vault), address(underlyingToken), 0.98e18);

        vm.prank(owner);
        strategy.setSlippageTolerance(10); // 0.1% tolerance — very tight

        vm.expectRevert("MockAMMAdapter: insufficient output amount");
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), 500e18, client);
    }

    /// @notice Test deposit succeeds when AMM output is within slippage tolerance
    function testDepositSucceedsWithinSlippage() public {
        // Set rate slightly below 1:1 (0.5% loss)
        ammAdapter.setExchangeRate(address(underlyingToken), address(erc4626Vault), 0.995e18);

        vm.prank(owner);
        strategy.setSlippageTolerance(100); // 1% tolerance

        // Should succeed — 0.5% loss is within 1% tolerance
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
    }

    // ============ PRINCIPAL TRACKING CONSISTENCY TESTS ============

    /// @notice Test principal tracking consistency (single user deposit+withdraw cycle)
    function testPrincipalTrackingSingleUser() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), depositAmount);

        // Withdraw half
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), 500e18, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 500e18);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), 500e18);
    }

    /// @notice Test principal tracking consistency (multi-user)
    function testPrincipalTrackingMultiUser() public {
        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        strategy.deposit(address(underlyingToken), 2000e18, user2);
        vm.stopPrank();

        assertEq(strategy.getTotalDeposited(address(underlyingToken)), 3000e18);

        // user1 withdraws entirely
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), 1000e18, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 0);
        assertEq(strategy.principalOf(address(underlyingToken), user2), 2000e18);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), 2000e18);
    }

    // ============ YIELD DISTRIBUTION TESTS ============

    /// @notice Test totalBalanceOf with no yield equals principalOf
    function testTotalBalanceOfNoYieldEqualsPrincipal() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        assertEq(
            strategy.totalBalanceOf(address(underlyingToken), user1),
            strategy.principalOf(address(underlyingToken), user1)
        );
        assertEq(strategy.totalBalanceOf(address(underlyingToken), user1), depositAmount);
    }

    /// @notice Test totalBalanceOf increases after vault yield simulation
    function testTotalBalanceOfIncreasesWithYield() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        // Simulate 10% yield in the vault
        erc4626Vault.simulateYield(100e18);

        uint256 totalBalance = strategy.totalBalanceOf(address(underlyingToken), user1);
        uint256 principal = strategy.principalOf(address(underlyingToken), user1);

        assertGt(totalBalance, principal);
    }

    /// @notice Test proportional yield distribution across multiple depositors
    function testProportionalYieldDistribution() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 4000e18;

        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), deposit1, user1);
        strategy.deposit(address(underlyingToken), deposit2, user2);
        vm.stopPrank();

        // Simulate yield
        erc4626Vault.simulateYield(2500e18);

        uint256 user1Total = strategy.totalBalanceOf(address(underlyingToken), user1);
        uint256 user2Total = strategy.totalBalanceOf(address(underlyingToken), user2);

        // User2 should have ~4x user1's total balance (since user2 deposited 4x)
        assertApproxEqAbs(user2Total, user1Total * 4, 2);
    }

    // ============ AUTHORIZATION TESTS ============

    /// @notice Test deposit reverts for unauthorized client
    function testDepositRevertsForUnauthorizedClient() public {
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(randomUser);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test withdraw reverts for unauthorized client
    function testWithdrawRevertsForUnauthorizedClient() public {
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(randomUser);
        strategy.withdraw(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test deposit reverts for wrong token
    function testDepositRevertsForWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);

        vm.expectRevert("ERC4626MarketYieldStrategy: only underlying token supported");
        vm.prank(client);
        strategy.deposit(address(wrongToken), 1000e18, user1);
    }

    /// @notice Test zero-amount deposit reverts
    function testZeroDepositReverts() public {
        vm.expectRevert("ERC4626MarketYieldStrategy: amount must be greater than zero");
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 0, user1);
    }

    /// @notice Test zero-amount withdraw reverts
    function testZeroWithdrawReverts() public {
        vm.expectRevert("ERC4626MarketYieldStrategy: amount must be greater than zero");
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), 0, user1);
    }

    // ============ PAUSE BEHAVIOR TESTS ============

    /// @notice Test deposit reverts when paused
    function testDepositRevertsWhenPaused() public {
        vm.prank(pauser);
        strategy.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test withdraw reverts when paused
    function testWithdrawRevertsWhenPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        vm.prank(pauser);
        strategy.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), 500e18, client);
    }

    /// @notice Test emergency withdraw still works when paused
    function testEmergencyWithdrawWorksWhenPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        vm.prank(pauser);
        strategy.pause();

        uint256 sharesToWithdraw = strategy.getTotalShares();

        uint256 ownerVaultSharesBefore = IERC20(address(erc4626Vault)).balanceOf(owner);

        // Emergency withdraw should still work when paused — transfers vault shares to owner
        vm.prank(owner);
        strategy.emergencyWithdraw(sharesToWithdraw);

        uint256 ownerVaultSharesAfter = IERC20(address(erc4626Vault)).balanceOf(owner);
        assertGt(ownerVaultSharesAfter, ownerVaultSharesBefore);
    }

    // ============ EMERGENCY WITHDRAW TESTS ============

    /// @notice Test emergency withdraw transfers vault tokens (shares) to owner
    function testEmergencyWithdrawTransfersVaultTokens() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        uint256 totalShares = strategy.getTotalShares();
        assertGt(totalShares, 0);

        uint256 ownerVaultSharesBefore = IERC20(address(erc4626Vault)).balanceOf(owner);

        vm.prank(owner);
        strategy.emergencyWithdraw(totalShares);

        uint256 ownerVaultSharesAfter = IERC20(address(erc4626Vault)).balanceOf(owner);
        assertEq(ownerVaultSharesAfter - ownerVaultSharesBefore, totalShares);

        // Strategy should have no shares left
        assertEq(strategy.getTotalShares(), 0);
    }

    /// @notice Test emergency withdraw with partial amount
    function testEmergencyWithdrawPartialAmount() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        uint256 totalShares = strategy.getTotalShares();
        uint256 halfShares = totalShares / 2;

        vm.prank(owner);
        strategy.emergencyWithdraw(halfShares);

        // Should have roughly half shares remaining
        assertApproxEqAbs(strategy.getTotalShares(), totalShares - halfShares, 1);
    }

    /// @notice Test emergency withdraw reverts with no shares
    function testEmergencyWithdrawRevertsNoShares() public {
        vm.expectRevert("ERC4626MarketYieldStrategy: no shares to withdraw");
        vm.prank(owner);
        strategy.emergencyWithdraw(1000e18);
    }

    // ============ SURPLUS WITHDRAWAL (skimSurplus) TESTS ============
    // New model: skimSurplus(token, recipient) skims the FULL surplus of EVERY authorized client
    // in a single AMM swap.

    /// @notice skimSurplus extracts surplus and never touches principal
    function testSkimSurplusOnlyAllowsSurplus() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Generate 10% yield
        erc4626Vault.simulateYield(1000e18);

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        // Principal MUST NOT change; full surplus skimmed -> total ~= principal
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount);
        assertApproxEqAbs(strategy.totalBalanceOf(address(underlyingToken), client), depositAmount, 2);
    }

    /// @notice skimSurplus never modifies principal across repeated calls
    function testSkimSurplusNeverModifiesPrincipal() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        uint256 principalBefore = strategy.principalOf(address(underlyingToken), client);

        // Repeated skims with fresh yield each round; principal stays constant
        for (uint256 i = 0; i < 5; i++) {
            erc4626Vault.simulateYield(200e18);
            vm.prank(withdrawer);
            strategy.skimSurplus(address(underlyingToken), withdrawer);
            assertEq(strategy.principalOf(address(underlyingToken), client), principalBefore);
        }

        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount);
    }

    /// @notice skimSurplus is a no-op (no swap) when there is no surplus
    function testSkimSurplusNoSurplusNoOp() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // No yield generated
        uint256 swapsBefore = ammAdapter.swapCount();
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        assertEq(ammAdapter.swapCount() - swapsBefore, 0, "no surplus => no swap");
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount);
    }

    // ============ TOTAL WITHDRAWAL TWO-PHASE TESTS ============

    /// @notice Test totalWithdrawal two-phase flow (initiate + execute)
    function testTotalWithdrawalTwoPhaseFlow() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Phase 1: Initiate withdrawal
        vm.prank(owner);
        strategy.totalWithdrawal(address(underlyingToken), client);

        // Advance past waiting period (24 hours)
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);

        // Phase 2: Execute withdrawal
        vm.prank(owner);
        strategy.totalWithdrawal(address(underlyingToken), client);

        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore);

        // Client balance should be zeroed out
        assertEq(strategy.principalOf(address(underlyingToken), client), 0);
    }

    /// @notice Test totalWithdrawal reverts during waiting period
    function testTotalWithdrawalRevertsDuringWaitingPeriod() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Phase 1: Initiate withdrawal
        vm.prank(owner);
        strategy.totalWithdrawal(address(underlyingToken), client);

        // Try to execute before waiting period ends
        vm.warp(block.timestamp + 12 hours);

        vm.expectRevert();
        vm.prank(owner);
        strategy.totalWithdrawal(address(underlyingToken), client);
    }

    // ============ OWNER SPOOF FUNCTION TESTS ============

    /// @notice Test depositAsOwner works for authorized owner
    function testDepositAsOwnerWorks() public {
        uint256 depositAmount = 1000e18;

        vm.prank(owner);
        strategy.depositAsOwner(address(underlyingToken), depositAmount, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), depositAmount);
    }

    /// @notice Test depositAsOwner reverts for non-owner
    function testDepositAsOwnerRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        strategy.depositAsOwner(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test withdrawAsOwner works for authorized owner
    function testWithdrawAsOwnerWorks() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        uint256 recipientBalanceBefore = underlyingToken.balanceOf(user2);

        // Owner withdraws from user1's balance, sending to user2
        vm.prank(owner);
        strategy.withdrawAsOwner(user1, user2, 500e18);

        uint256 recipientBalanceAfter = underlyingToken.balanceOf(user2);
        assertGt(recipientBalanceAfter, recipientBalanceBefore);
        assertEq(strategy.principalOf(address(underlyingToken), user1), 500e18);
    }

    /// @notice Test withdrawAsOwner reverts for non-owner
    function testWithdrawAsOwnerRevertsForNonOwner() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        strategy.withdrawAsOwner(user1, user2, 500e18);
    }

    /// @notice Test depositAsOwner works when paused
    function testDepositAsOwnerWorksWhenPaused() public {
        vm.prank(pauser);
        strategy.pause();

        // Should still work
        vm.prank(owner);
        strategy.depositAsOwner(address(underlyingToken), 1000e18, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
    }

    /// @notice Test withdrawAsOwner works when paused
    function testWithdrawAsOwnerWorksWhenPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        vm.prank(pauser);
        strategy.pause();

        // Should still work
        vm.prank(owner);
        strategy.withdrawAsOwner(user1, owner, 500e18);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 500e18);
    }

    // ============ VIEW FUNCTION TESTS ============

    function testUnderlyingReturnsCorrectAddress() public view {
        assertEq(strategy.underlying(), address(underlyingToken));
    }

    function testGetTotalDepositedTracksCorrectly() public {
        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
        strategy.deposit(address(underlyingToken), 2000e18, user2);
        vm.stopPrank();

        assertEq(strategy.getTotalDeposited(address(underlyingToken)), 3000e18);
    }

    function testGetTotalSharesTracksCorrectly() public {
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);

        assertGt(strategy.getTotalShares(), 0);
    }

    /// @notice Test balanceOf returns same as principalOf (backward compat)
    function testBalanceOfReturnsPrincipalOf() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        // Add yield to ensure they diverge from totalBalanceOf
        erc4626Vault.simulateYield(100e18);

        // balanceOf should return principal, not total
        assertEq(
            strategy.balanceOf(address(underlyingToken), user1), strategy.principalOf(address(underlyingToken), user1)
        );
        assertEq(strategy.balanceOf(address(underlyingToken), user1), depositAmount);
    }

    /// @notice Test principalOf reverts for wrong token
    function testPrincipalOfWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);
        vm.expectRevert("ERC4626MarketYieldStrategy: only underlying token supported");
        strategy.principalOf(address(wrongToken), user1);
    }

    /// @notice Test totalBalanceOf reverts for wrong token
    function testTotalBalanceOfWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);
        vm.expectRevert("ERC4626MarketYieldStrategy: only underlying token supported");
        strategy.totalBalanceOf(address(wrongToken), user1);
    }

    // ============ CONSTRUCTOR VALIDATION TESTS ============

    function testConstructorRevertsZeroUnderlying() public {
        vm.expectRevert("ERC4626MarketYieldStrategy: underlying token cannot be zero address");
        vm.prank(owner);
        new ERC4626MarketYieldStrategy(owner, address(0), address(erc4626Vault), address(ammAdapter));
    }

    function testConstructorRevertsZeroVault() public {
        vm.expectRevert("ERC4626MarketYieldStrategy: vault cannot be zero address");
        vm.prank(owner);
        new ERC4626MarketYieldStrategy(owner, address(underlyingToken), address(0), address(ammAdapter));
    }

    function testConstructorRevertsZeroAdapter() public {
        vm.expectRevert("ERC4626MarketYieldStrategy: AMM adapter cannot be zero address");
        vm.prank(owner);
        new ERC4626MarketYieldStrategy(owner, address(underlyingToken), address(erc4626Vault), address(0));
    }

    // ============ AMM EXCHANGE RATE VARIATIONS ============

    /// @notice Test deposit with favorable AMM rate (more shares than ideal)
    function testDepositWithFavorableAMMRate() public {
        // AMM gives 2% more shares than vault price suggests
        ammAdapter.setExchangeRate(address(underlyingToken), address(erc4626Vault), 1.02e18);

        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);

        // Principal tracks input amount, not received shares
        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);

        // Should have more shares than a 1:1 deposit
        assertGt(strategy.getTotalShares(), 1000e18);
    }

    /// @notice Test withdraw with slight AMM discount (receives slightly less)
    function testWithdrawWithAMMDiscount() public {
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, client);

        // AMM gives 0.5% less underlying than ideal
        ammAdapter.setExchangeRate(address(erc4626Vault), address(underlyingToken), 0.995e18);

        uint256 balanceBefore = underlyingToken.balanceOf(client);

        vm.prank(client);
        strategy.withdraw(address(underlyingToken), 500e18, client);

        uint256 received = underlyingToken.balanceOf(client) - balanceBefore;

        // Principal decremented by requested 500, not received amount
        assertEq(strategy.principalOf(address(underlyingToken), client), 500e18);
        // Received should be slightly less than requested
        assertLt(received, 500e18);
    }

    // ============ skimSurplus (all-clients, single-swap) TESTS ============
    // The strategy owns the authorized-client set; skimSurplus iterates it internally.

    event SurplusSkimmed(
        address indexed token, address indexed client, address indexed withdrawer, uint256 amount, address recipient
    );

    /// @dev Authorize an address as a client and credit it with `amount` principal (deposit to self).
    function _authorizeAndDeposit(address c, uint256 amount) internal {
        vm.prank(owner);
        strategy.setClient(c, true);
        underlyingToken.mint(c, amount);
        vm.startPrank(c);
        underlyingToken.approve(address(strategy), type(uint256).max);
        strategy.deposit(address(underlyingToken), amount, c);
        vm.stopPrank();
    }

    /// @notice Skim over multiple authorized clients performs EXACTLY ONE swap, aggregated amountIn
    function testSkimSurplusSingleSwap() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 2000e18);
        _authorizeAndDeposit(user3, 3000e18);

        // 10% yield on 6000 => 600 surplus
        erc4626Vault.simulateYield(600e18);

        // Expected aggregate shares = sum of per-client floored convertToShares(surplus_c)
        uint256 td = strategy.getTotalDeposited(address(underlyingToken));
        uint256 totalValue = erc4626Vault.convertToAssets(erc4626Vault.balanceOf(address(strategy)));
        uint256 expectedShares;
        address[] memory clients = new address[](3);
        clients[0] = user1;
        clients[1] = user2;
        clients[2] = user3;
        for (uint256 i = 0; i < clients.length; i++) {
            uint256 principal = strategy.principalOf(address(underlyingToken), clients[i]);
            uint256 total = (totalValue * principal) / td;
            uint256 surplus = total > principal ? total - principal : 0;
            expectedShares += erc4626Vault.convertToShares(surplus);
        }

        uint256 swapsBefore = ammAdapter.swapCount();

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        // Exactly one swap for the whole client set
        assertEq(ammAdapter.swapCount() - swapsBefore, 1, "skim must do exactly one swap");
        // amountIn proves aggregation across all clients
        assertEq(ammAdapter.lastAmountIn(), expectedShares, "swap amountIn == aggregated shares");
    }

    /// @notice Skim leaves principal / getTotalDeposited unchanged
    function testSkimSurplusAllClientsPrincipalUnchanged() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 2000e18);

        erc4626Vault.simulateYield(300e18);

        uint256 totalDepositedBefore = strategy.getTotalDeposited(address(underlyingToken));

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
        assertEq(strategy.principalOf(address(underlyingToken), user2), 2000e18);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), totalDepositedBefore);
    }

    /// @notice One SurplusSkimmed event per surplus-bearing client
    function testSkimSurplusEmitsPerSurplusClient() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 1000e18);

        erc4626Vault.simulateYield(200e18);

        uint256 surplus1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        uint256 surplus2 = strategy.totalBalanceOf(address(underlyingToken), user2)
            - strategy.principalOf(address(underlyingToken), user2);

        // Iteration order: client (setUp, no principal -> skipped), user1, user2.
        vm.expectEmit(true, true, true, true);
        emit SurplusSkimmed(address(underlyingToken), user1, withdrawer, surplus1, withdrawer);
        vm.expectEmit(true, true, true, true);
        emit SurplusSkimmed(address(underlyingToken), user2, withdrawer, surplus2, withdrawer);

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);
    }

    /// @notice Zero-principal authorized clients are skipped (still one swap for the rest)
    function testSkimSurplusSkipsZeroSurplusClient() public {
        _authorizeAndDeposit(user1, 1000e18);
        // user2 and user3 authorized but never deposited => zero principal => skipped
        vm.startPrank(owner);
        strategy.setClient(user2, true);
        strategy.setClient(user3, true);
        vm.stopPrank();

        erc4626Vault.simulateYield(100e18);

        uint256 swapsBefore = ammAdapter.swapCount();

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        assertEq(ammAdapter.swapCount() - swapsBefore, 1, "one swap despite zero-surplus clients");
        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
    }

    /// @notice No-op (no swap) when there is no surplus at all
    function testSkimSurplusNoSurplusNoSwap() public {
        _authorizeAndDeposit(user1, 1000e18);

        uint256 swapsBefore = ammAdapter.swapCount();

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        assertEq(ammAdapter.swapCount() - swapsBefore, 0, "no swap when no surplus");
    }

    /// @notice minOut is computed on the AGGREGATE: a sub-minOut AMM rate reverts the whole skim
    function testSkimSurplusMinOutOnAggregateReverts() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 1000e18);

        erc4626Vault.simulateYield(400e18);

        // Tight tolerance, then set sell rate below it
        vm.prank(owner);
        strategy.setSlippageTolerance(10); // 0.1%
        ammAdapter.setExchangeRate(address(erc4626Vault), address(underlyingToken), 0.98e18); // 2% loss

        vm.expectRevert("MockAMMAdapter: insufficient output amount");
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);
    }

    // ---- guard / access cases ----

    function testSkimSurplusRevertsForNonWithdrawer() public {
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized withdrawers");
        vm.prank(randomUser);
        strategy.skimSurplus(address(underlyingToken), withdrawer);
    }

    function testSkimSurplusRevertsWhenPaused() public {
        vm.prank(pauser);
        strategy.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);
    }

    function testSkimSurplusRevertsZeroToken() public {
        vm.expectRevert("AYieldStrategy: token cannot be zero address");
        vm.prank(withdrawer);
        strategy.skimSurplus(address(0), withdrawer);
    }

    function testSkimSurplusRevertsZeroRecipient() public {
        vm.expectRevert("AYieldStrategy: recipient cannot be zero address");
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), address(0));
    }
}
