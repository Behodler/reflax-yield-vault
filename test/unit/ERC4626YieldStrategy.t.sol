// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import "../../src/mocks/MockERC20.sol";
import "../mocks/MockERC4626Vault.sol";
import "../mocks/MockStateChangingPreviewVault.sol";

/**
 * @title ERC4626YieldStrategyTest
 * @notice Comprehensive unit tests for ERC4626YieldStrategy
 * @dev Covers deposit/withdraw tracking, yield distribution, rounding, pause behavior,
 *      access control, owner spoof functions, emergency withdraw, totalWithdrawal two-phase,
 *      fee-charging vaults, and edge cases.
 */
contract ERC4626YieldStrategyTest is Test {
    ERC4626YieldStrategy strategy;
    MockERC20 underlyingToken;
    MockERC4626Vault erc4626Vault;

    address owner = address(0x1234);
    address client = address(0x5678);
    address pauser = address(0x9ABC);
    address user1 = address(0xDEF0);
    address user2 = address(0x1357);
    address user3 = address(0x2468);
    address withdrawer = address(0xABCD);
    address randomUser = address(0xBEEF);
    address bufferRecipient = address(0xCAFE);

    uint256 constant INITIAL_TOKEN_SUPPLY = 10_000_000e18;

    function setUp() public {
        // Deploy mock tokens
        underlyingToken = new MockERC20("Underlying", "UNDERLYING", 18);

        // Deploy mock ERC4626 vault
        erc4626Vault = new MockERC4626Vault("Vault Shares", "vUNDERLYING", address(underlyingToken));

        // Deploy the strategy
        vm.prank(owner);
        strategy = new ERC4626YieldStrategy(owner, address(underlyingToken), address(erc4626Vault));

        // Mint tokens
        underlyingToken.mint(client, INITIAL_TOKEN_SUPPLY);
        underlyingToken.mint(owner, INITIAL_TOKEN_SUPPLY);

        // Authorize client, withdrawer, pauser
        vm.startPrank(owner);
        strategy.setClient(client, true);
        strategy.setWithdrawer(withdrawer, true);
        strategy.setPauser(pauser);
        vm.stopPrank();

        // Approve strategy to spend client's tokens
        vm.prank(client);
        underlyingToken.approve(address(strategy), type(uint256).max);

        // Approve strategy to spend owner's tokens (for depositAsOwner)
        vm.prank(owner);
        underlyingToken.approve(address(strategy), type(uint256).max);
    }

    // ============ DEPOSIT TRACKING TESTS ============

    /// @notice Test single-user deposit and verify principal tracking
    function testSingleUserDeposit() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), depositAmount);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), depositAmount);
        assertGt(strategy.getTotalShares(), 0);
    }

    /// @notice Test multi-user deposits and verify independent principal tracking
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

    // ============ DEPOSIT RETURN VALUE TESTS (story 044) ============

    /// @notice deposit() returns exactly the nominal amount (full-credit default) == principalOf delta.
    function testDepositReturnsAmount() public {
        uint256 amount = 1000e18;

        uint256 principalBefore = strategy.principalOf(address(underlyingToken), user1);
        uint256 totalBefore = strategy.getTotalDeposited(address(underlyingToken));

        vm.prank(client);
        uint256 credited = strategy.deposit(address(underlyingToken), amount, user1);

        assertEq(credited, amount, "direct strategy returns the nominal amount");
        assertEq(
            credited,
            strategy.principalOf(address(underlyingToken), user1) - principalBefore,
            "return == principalOf delta"
        );
        assertEq(
            credited,
            strategy.getTotalDeposited(address(underlyingToken)) - totalBefore,
            "return == getTotalDeposited delta"
        );
    }

    /// @notice depositAsOwner() also returns the nominal amount for the direct strategy.
    function testDepositAsOwnerReturnsAmount() public {
        uint256 amount = 1000e18;

        vm.prank(owner);
        uint256 credited = strategy.depositAsOwner(address(underlyingToken), amount, user1);

        assertEq(credited, amount, "depositAsOwner returns the nominal amount");
        assertEq(credited, strategy.principalOf(address(underlyingToken), user1), "return == credited principal");
    }

    // ============ totalBalanceOf() TESTS ============

    /// @notice Test totalBalanceOf() with no yield equals principalOf()
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

    /// @notice Test totalBalanceOf() increases after simulateYield() on mock vault
    function testTotalBalanceOfIncreasesWithYield() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        // Simulate 10% yield
        erc4626Vault.simulateYield(100e18);

        uint256 totalBalance = strategy.totalBalanceOf(address(underlyingToken), user1);
        uint256 principal = strategy.principalOf(address(underlyingToken), user1);

        assertGt(totalBalance, principal);
        assertApproxEqAbs(totalBalance, 1100e18, 1);
    }

    /// @notice Test proportional yield distribution across multiple depositors
    function testProportionalYieldDistribution() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 4000e18;

        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), deposit1, user1);
        strategy.deposit(address(underlyingToken), deposit2, user2);
        vm.stopPrank();

        // Simulate 50% yield (5000 total becomes 7500)
        erc4626Vault.simulateYield(2500e18);

        uint256 user1Total = strategy.totalBalanceOf(address(underlyingToken), user1);
        uint256 user2Total = strategy.totalBalanceOf(address(underlyingToken), user2);

        // User2 should have 4x user1's total balance
        assertApproxEqAbs(user2Total, user1Total * 4, 1);

        // Verify approximate values
        assertApproxEqAbs(user1Total, 1500e18, 1); // 1000 + 500
        assertApproxEqAbs(user2Total, 6000e18, 1); // 4000 + 2000
    }

    // ============ WITHDRAW TESTS ============

    /// @notice Test withdraw() returns correct amount and updates principal
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

    /// @notice Test withdraw() rounding favors protocol (requested > received is OK)
    function testWithdrawRoundingFavorsProtocol() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Simulate some yield so share price changes
        erc4626Vault.simulateYield(100e18);

        uint256 withdrawAmount = 500e18;
        uint256 balanceBefore = underlyingToken.balanceOf(client);

        vm.prank(client);
        strategy.withdraw(address(underlyingToken), withdrawAmount, client);

        uint256 received = underlyingToken.balanceOf(client) - balanceBefore;

        // Principal decremented by requested amount (500), not received amount
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount - withdrawAmount);

        // Received should be <= requested (rounding favors protocol)
        assertLe(received, withdrawAmount);
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

    // ============ skimSurplus() SURPLUS EXTRACTION TESTS ============
    // New model: skimSurplus(token, recipient) skims the FULL surplus of EVERY authorized client.

    /// @notice skimSurplus extracts surplus and never touches principal
    function testSkimSurplusOnlyAllowsSurplus() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Authorize `client` as a yield client too (it is the authorized client in setUp)
        // Generate 10% yield (1000 tokens surplus)
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

    // ============ EMERGENCY WITHDRAW TESTS ============

    /// @notice Test _emergencyWithdraw() works when NOT paused
    function testEmergencyWithdrawWorksWhenNotPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);

        vm.prank(owner);
        strategy.emergencyWithdraw(500e18);

        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore);
    }

    /// @notice Test _emergencyWithdraw() works when contract IS paused
    function testEmergencyWithdrawWorksWhenPaused() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Pause the contract
        vm.prank(pauser);
        strategy.pause();

        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);

        // Emergency withdraw should still work when paused
        vm.prank(owner);
        strategy.emergencyWithdraw(500e18);

        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore);
    }

    // ============ TOTAL WITHDRAWAL TWO-PHASE TESTS ============

    /// @notice Test totalWithdrawal() two-phase flow (initiate + execute)
    function testTotalWithdrawalTwoPhaseFlow() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // Phase 1: Initiate withdrawal
        vm.prank(owner);
        strategy.totalWithdrawal(address(underlyingToken), client);

        // Advance past waiting period (6 hours)
        vm.warp(block.timestamp + 6 hours + 1);

        uint256 ownerBalanceBefore = underlyingToken.balanceOf(owner);

        // Phase 2: Execute withdrawal
        vm.prank(owner);
        strategy.totalWithdrawal(address(underlyingToken), client);

        uint256 ownerBalanceAfter = underlyingToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore);

        // Client balance should be zeroed out
        assertEq(strategy.principalOf(address(underlyingToken), client), 0);
    }

    // ============ OWNER SPOOF FUNCTION TESTS ============

    /// @notice Test withdrawAsOwner() works for authorized owner
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

    /// @notice Test withdrawAsOwner() reverts for non-owner
    function testWithdrawAsOwnerRevertsForNonOwner() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        strategy.withdrawAsOwner(user1, user2, 500e18);
    }

    /// @notice Test depositAsOwner() works for authorized owner
    function testDepositAsOwnerWorks() public {
        uint256 depositAmount = 1000e18;

        vm.prank(owner);
        strategy.depositAsOwner(address(underlyingToken), depositAmount, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), depositAmount);
    }

    /// @notice Test depositAsOwner() reverts for non-owner
    function testDepositAsOwnerRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        strategy.depositAsOwner(address(underlyingToken), 1000e18, user1);
    }

    // ============ ACCESS CONTROL TESTS ============

    /// @notice Test deposit() reverts for unauthorized client
    function testDepositRevertsForUnauthorizedClient() public {
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(randomUser);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test withdraw() reverts for unauthorized client
    function testWithdrawRevertsForUnauthorizedClient() public {
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        vm.prank(randomUser);
        strategy.withdraw(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test deposit() reverts for wrong token
    function testDepositRevertsForWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);

        vm.expectRevert("AYieldStrategy: only underlying token supported");
        vm.prank(client);
        strategy.deposit(address(wrongToken), 1000e18, user1);
    }

    // ============ PAUSE BEHAVIOR TESTS ============

    /// @notice Test deposit() reverts when paused
    function testDepositRevertsWhenPaused() public {
        vm.prank(pauser);
        strategy.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 1000e18, user1);
    }

    /// @notice Test withdraw() reverts when paused
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

    // ============ FEE-CHARGING VAULT TESTS ============

    /// @notice Test with fee-charging mock vault (entry fee deducts shares; principal tracks
    ///         vault.previewRedeem(sharesReceived) — the position value, NOT the raw nominal input)
    /// @dev The fix from story-048: creditedPrincipal = vault.previewRedeem(sharesReceived).
    ///      For the FIRST deposit into a fresh vault, previewRedeem(shares) == nominal amount
    ///      because share price is still 1:1. For SUBSEQUENT deposits, when the share price has
    ///      risen above 1 (due to fee revenue accumulating in totalAssets), previewRedeem gives
    ///      less than the nominal input — correctly reflecting the actual position acquired.
    function testFeeChargingVault() public {
        // Set 5% entry fee on vault
        erc4626Vault.setFeeBps(500); // 5%

        // First deposit: user1 deposits 1000
        uint256 deposit1 = 1000e18;
        vm.prank(client);
        strategy.deposit(address(underlyingToken), deposit1, user1);

        // After first deposit into a fresh vault: 950 shares minted, totalAssets = 1000.
        // previewRedeem(950) = 950 * 1000 / 950 = 1000 == deposit1.
        assertEq(strategy.principalOf(address(underlyingToken), user1), deposit1, "first deposit: principal == nominal");

        // Shares should be fewer than deposit amount (950 shares for 1000 assets)
        uint256 shares1 = strategy.getTotalShares();
        assertLt(shares1, deposit1, "Shares should be less than deposit due to fee");

        // Second deposit: user2 deposits 1000
        // Vault state: totalAssets=1000, totalSupply=950. Share price = 1000/950 > 1.
        // effectiveAssets = 950 (after 5% fee), shares received = 950 * 950 / 1000 = 902 (truncated).
        // totalAssets becomes 2000, totalSupply becomes 1852.
        // previewRedeem(902) = 902 * 2000 / 1852 ≈ 974 (the actual credited position value).
        uint256 deposit2 = 1000e18;
        vm.prank(client);
        uint256 credited2 = strategy.deposit(address(underlyingToken), deposit2, user2);

        // Principal reflects the real position value (previewRedeem), NOT the full nominal input.
        // The gap between nominal and credited is protocol-owned yield (fee revenue).
        assertEq(strategy.principalOf(address(underlyingToken), user2), credited2, "principal == creditedPrincipal");
        assertLt(credited2, deposit2, "fee-charged second deposit: credited < nominal");

        // Total deposited = deposit1 + credited2 (not deposit1 + deposit2 any more)
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), deposit1 + credited2);

        // creditedPrincipal is the position value at deposit time (previewRedeem(shares)), which is
        // the second depositor's share of the vault at the moment of deposit. After deposit, the
        // totalDeposited denominator includes both credited principals, so totalBalanceOf gives the
        // depositor a proportional claim that may be slightly different. The invariant to check is
        // that the credited principal is less than the nominal and that the total deposited is correct.
        assertLt(credited2, deposit2, "credited principal < nominal deposit due to fee");
        assertGt(strategy.totalBalanceOf(address(underlyingToken), user2), 0, "user2 has positive totalBalance");
    }

    // ============ YS-01: STATE-CHANGING previewRedeem (AUTOPOOL STATICCALL) TESTS ============

    /// @notice YS-01 regression: depositing into a strategy that wraps a vault whose `previewRedeem`
    ///         mutates state (a faithful Tokemak-Autopool simulation) must NOT revert, because the
    ///         fixed credit path uses `convertToAssets` (STATICCALL-safe) instead of `previewRedeem`.
    /// @dev Pre-fix (creditedPrincipal = vault.previewRedeem(sharesReceived)) this deposit reverts
    ///      with StateChangeDuringStaticCall. Post-fix it credits convertToAssets(sharesReceived).
    ///      The vault is seeded to a non-1:1 share ratio so convertToAssets(shares) != shares,
    ///      proving the credit is the real exchange-rate value (not a trivial pass-through).
    function testAcquireShares_StateChangingPreviewRedeem_Succeeds() public {
        // Deploy a strategy over the state-changing-previewRedeem mock.
        MockStateChangingPreviewVault scVault =
            new MockStateChangingPreviewVault("SC Vault", "scV", address(underlyingToken));
        vm.prank(owner);
        ERC4626YieldStrategy scStrategy = new ERC4626YieldStrategy(owner, address(underlyingToken), address(scVault));

        vm.prank(owner);
        scStrategy.setClient(client, true);
        vm.prank(client);
        underlyingToken.approve(address(scStrategy), type(uint256).max);

        // Seed the vault to a non-1:1 ratio: a 1000-asset deposit mints 1000 shares, then yield is
        // added so convertToAssets(shares) > shares (share price > 1).
        vm.prank(client);
        scStrategy.deposit(address(underlyingToken), 1000e18, user2);
        scVault.simulateYield(500e18); // totalAssets 1500, supply 1000 -> price 1.5

        // Sanity: ratio is now non-1:1 so convertToAssets is not a trivial identity.
        assertGt(scVault.convertToAssets(1e18), 1e18, "ratio must be non-1:1 for a meaningful credit");

        // Deposit as client for user1 — must NOT revert (pre-fix: StateChangeDuringStaticCall).
        uint256 sharesBefore = scVault.balanceOf(address(scStrategy));
        vm.prank(client);
        scStrategy.deposit(address(underlyingToken), 1000e18, user1);
        uint256 sharesReceived = scVault.balanceOf(address(scStrategy)) - sharesBefore;

        // Credited principal == convertToAssets(sharesReceived), the STATICCALL-safe exchange value.
        assertEq(
            scStrategy.principalOf(address(underlyingToken), user1),
            scVault.convertToAssets(sharesReceived),
            "principal == convertToAssets(sharesReceived)"
        );
    }

    /// @notice YS-01 root-cause isolation (mirrors the audit's on-chain check): a low-level
    ///         STATICCALL to the mock's `previewRedeem` reverts, while a STATICCALL to
    ///         `convertToAssets` succeeds — documenting the mechanism independently of the strategy.
    function testRootCause_PreviewRedeemReverts_ConvertToAssetsSucceeds() public {
        MockStateChangingPreviewVault scVault =
            new MockStateChangingPreviewVault("SC Vault", "scV", address(underlyingToken));

        // STATICCALL to previewRedeem must fail (state write under static frame).
        (bool prSuccess,) =
            address(scVault).staticcall(abi.encodeWithSignature("previewRedeem(uint256)", uint256(1e18)));
        assertFalse(prSuccess, "previewRedeem must revert under STATICCALL");

        // STATICCALL to convertToAssets must succeed (purely arithmetic).
        (bool ctaSuccess,) =
            address(scVault).staticcall(abi.encodeWithSignature("convertToAssets(uint256)", uint256(1e18)));
        assertTrue(ctaSuccess, "convertToAssets must succeed under STATICCALL");
    }

    // ============ ZERO-AMOUNT EDGE CASES ============

    /// @notice Test zero-amount deposit reverts
    function testZeroDepositReverts() public {
        vm.expectRevert("AYieldStrategy: amount must be greater than zero");
        vm.prank(client);
        strategy.deposit(address(underlyingToken), 0, user1);
    }

    /// @notice Test zero-amount withdraw reverts
    function testZeroWithdrawReverts() public {
        vm.expectRevert("AYieldStrategy: amount must be greater than zero");
        vm.prank(client);
        strategy.withdraw(address(underlyingToken), 0, user1);
    }

    // ============ balanceOf() BACKWARD COMPATIBILITY TESTS ============

    /// @notice Test balanceOf() returns same as principalOf() (backward compat)
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
        assertLt(
            strategy.balanceOf(address(underlyingToken), user1),
            strategy.totalBalanceOf(address(underlyingToken), user1)
        );
    }

    // ============ PREVIEW FUNCTION TESTS (story 048) ============

    /// @notice previewDeposit delegates to vault.previewDeposit (1:1 no-fee vault)
    function testPreviewDepositDelegatesToVault() public view {
        uint256 assets = 1000e18;
        uint256 strategyPreview = strategy.previewDeposit(assets);
        uint256 vaultPreview = erc4626Vault.previewDeposit(assets);
        assertEq(strategyPreview, vaultPreview, "previewDeposit must delegate to vault exactly");
    }

    /// @notice previewRedeem delegates to vault.previewRedeem (1:1 no-fee vault)
    function testPreviewRedeemDelegatesToVault() public {
        uint256 depositAmount = 1000e18;
        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        uint256 shares = strategy.getTotalShares();
        uint256 strategyPreview = strategy.previewRedeem(shares);
        uint256 vaultPreview = erc4626Vault.previewRedeem(shares);
        assertEq(strategyPreview, vaultPreview, "previewRedeem must delegate to vault exactly");
    }

    /// @notice previewDeposit with a fee-charging vault returns fewer shares than assets
    function testPreviewDepositFeeChargingVault() public {
        erc4626Vault.setFeeBps(500); // 5% fee

        uint256 assets = 1000e18;
        uint256 strategyPreview = strategy.previewDeposit(assets);
        uint256 vaultPreview = erc4626Vault.previewDeposit(assets);
        assertEq(strategyPreview, vaultPreview, "previewDeposit delegates to vault with fee");
        // With 5% fee on fresh vault, effective assets = 950, shares = 950
        assertEq(strategyPreview, 950e18, "5% fee vault: previewDeposit(1000) == 950 shares");
    }

    /// @notice previewRedeem after yield increase returns more assets than original shares
    function testPreviewRedeemAfterYield() public {
        uint256 depositAmount = 1000e18;
        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, user1);

        uint256 sharesBefore = strategy.getTotalShares();
        // Before yield: previewRedeem(shares) ~= depositAmount
        assertApproxEqAbs(strategy.previewRedeem(sharesBefore), depositAmount, 1, "pre-yield preview == deposit");

        // After 10% yield: previewRedeem should return more
        erc4626Vault.simulateYield(100e18);
        uint256 previewAfter = strategy.previewRedeem(sharesBefore);
        assertApproxEqAbs(previewAfter, 1100e18, 1, "post-yield preview == deposit + yield");
        assertGt(previewAfter, depositAmount, "post-yield preview exceeds original deposit");
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

        // Shares should be > 0 after deposit
        assertGt(strategy.getTotalShares(), 0);
    }

    // ============ OWNER SPOOF DOES NOT REQUIRE whenNotPaused ============

    /// @notice Verify withdrawAsOwner works when paused
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

    /// @notice Verify depositAsOwner works when paused
    function testDepositAsOwnerWorksWhenPaused() public {
        vm.prank(pauser);
        strategy.pause();

        // Should still work
        vm.prank(owner);
        strategy.depositAsOwner(address(underlyingToken), 1000e18, user1);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
    }

    // ============ NO SURPLUS SCENARIO ============

    /// @notice skimSurplus is a no-op (no redeem) when there is no surplus
    function testSkimSurplusNoSurplusNoOp() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        // No yield generated
        uint256 redeemsBefore = erc4626Vault.redeemCount();
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 0, "no surplus => no redeem");
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount);
    }

    // ============ VAULT APPRECIATION SCENARIO ============

    function testVaultAppreciationOverTime() public {
        uint256 deposit = 1000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), deposit, user1);

        // Initial: no yield
        assertEq(strategy.totalBalanceOf(address(underlyingToken), user1), deposit);

        // First yield: +10%
        erc4626Vault.simulateYield(100e18);
        assertApproxEqAbs(strategy.totalBalanceOf(address(underlyingToken), user1), 1100e18, 1);

        // Second yield: another +10% on top (1100 + 110 = 1210)
        erc4626Vault.simulateYield(110e18);
        assertApproxEqAbs(strategy.totalBalanceOf(address(underlyingToken), user1), 1210e18, 1);

        // Principal never changes
        assertEq(strategy.principalOf(address(underlyingToken), user1), deposit);
    }

    // ============ SUM OF BALANCES EQUALS VAULT VALUE ============

    function testSumOfBalancesEqualsVaultValue() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 2000e18;
        uint256 deposit3 = 3000e18;

        vm.startPrank(client);
        strategy.deposit(address(underlyingToken), deposit1, user1);
        strategy.deposit(address(underlyingToken), deposit2, user2);
        strategy.deposit(address(underlyingToken), deposit3, user3);
        vm.stopPrank();

        // Add yield
        erc4626Vault.simulateYield(600e18);

        uint256 user1Total = strategy.totalBalanceOf(address(underlyingToken), user1);
        uint256 user2Total = strategy.totalBalanceOf(address(underlyingToken), user2);
        uint256 user3Total = strategy.totalBalanceOf(address(underlyingToken), user3);
        uint256 sumTotal = user1Total + user2Total + user3Total;

        // Get actual vault value
        uint256 totalShares = erc4626Vault.balanceOf(address(strategy));
        uint256 totalValue = erc4626Vault.convertToAssets(totalShares);

        // Sum should equal total vault value (within rounding tolerance)
        assertApproxEqAbs(sumTotal, totalValue, 3);
    }

    // ============ WITHDRAW EXACT SURPLUS ============

    function testSkimSurplusDrainsToPrincipal() public {
        uint256 depositAmount = 10000e18;

        vm.prank(client);
        strategy.deposit(address(underlyingToken), depositAmount, client);

        erc4626Vault.simulateYield(500e18);

        uint256 principal = strategy.principalOf(address(underlyingToken), client);

        // Skim the full surplus of all authorized clients
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        // Principal unchanged
        assertEq(strategy.principalOf(address(underlyingToken), client), depositAmount);

        // After skimming all surplus, totalBalanceOf should approx equal principal
        uint256 totalBalanceAfter = strategy.totalBalanceOf(address(underlyingToken), client);
        assertApproxEqAbs(totalBalanceAfter, principal, 1);
    }

    // ============ MULTIPLE USERS WITH DIFFERENT PRINCIPALS ============

    function testMultipleUsersWithDifferentPrincipals() public {
        uint256[] memory deposits = new uint256[](3);
        deposits[0] = 500e18;
        deposits[1] = 1500e18;
        deposits[2] = 3000e18;

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        vm.startPrank(client);
        for (uint256 i = 0; i < users.length; i++) {
            strategy.deposit(address(underlyingToken), deposits[i], users[i]);
        }
        vm.stopPrank();

        // Add 40% yield (5000 total becomes 7000)
        erc4626Vault.simulateYield(2000e18);

        // Verify totalBalanceOf proportions
        for (uint256 i = 0; i < users.length; i++) {
            uint256 expectedTotal = (deposits[i] * 7000e18) / 5000e18;
            assertApproxEqAbs(strategy.totalBalanceOf(address(underlyingToken), users[i]), expectedTotal, 1);
        }
    }

    // ============ WRONG TOKEN FOR VIEW FUNCTIONS ============

    function testPrincipalOfWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);
        vm.expectRevert("AYieldStrategy: only underlying token supported");
        strategy.principalOf(address(wrongToken), user1);
    }

    function testTotalBalanceOfWrongToken() public {
        MockERC20 wrongToken = new MockERC20("Wrong", "WRONG", 18);
        vm.expectRevert("AYieldStrategy: only underlying token supported");
        strategy.totalBalanceOf(address(wrongToken), user1);
    }

    // ============ skimSurplus (all-clients, single-redeem) TESTS ============
    // The strategy owns the authorized-client set; skimSurplus iterates it internally.
    // Clients deposit on their own behalf (recipient == self) so each is an authorized set member.

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

    /// @notice Skim over multiple authorized clients performs EXACTLY ONE redeem
    function testSkimSurplusSingleRedeem() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 2000e18);
        _authorizeAndDeposit(user3, 3000e18);

        // 10% yield on 6000 total => 600 surplus
        erc4626Vault.simulateYield(600e18);

        uint256 redeemsBefore = erc4626Vault.redeemCount();

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        // Exactly one redeem for the whole client set
        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 1, "skim must do exactly one redeem");
    }

    /// @notice Recipient receives approximately the sum of snapshot surpluses (protocol-favoring dust)
    function testSkimSurplusRecipientGetsSumOfSurplus() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 3000e18);

        // 25% yield on 4000 => 1000 surplus total
        erc4626Vault.simulateYield(1000e18);

        uint256 surplus1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        uint256 surplus2 = strategy.totalBalanceOf(address(underlyingToken), user2)
            - strategy.principalOf(address(underlyingToken), user2);
        uint256 expectedSum = surplus1 + surplus2;

        uint256 recipientBefore = underlyingToken.balanceOf(withdrawer);

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        uint256 received = underlyingToken.balanceOf(withdrawer) - recipientBefore;

        // Received <= expected (protocol-favoring rounding), within small dust tolerance
        assertLe(received, expectedSum, "should not exceed snapshot surplus sum");
        assertApproxEqAbs(received, expectedSum, 5, "received approx sum of snapshot surplus");
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

        // Iteration order is the set's insertion order: client (setUp), user1, user2.
        // client has no principal -> skipped. Expect events for user1 then user2.
        vm.expectEmit(true, true, true, true);
        emit SurplusSkimmed(address(underlyingToken), user1, withdrawer, surplus1, withdrawer);
        vm.expectEmit(true, true, true, true);
        emit SurplusSkimmed(address(underlyingToken), user2, withdrawer, surplus2, withdrawer);

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);
    }

    /// @notice Zero-principal authorized clients are skipped (no event, still one redeem for the rest)
    function testSkimSurplusSkipsZeroSurplusClient() public {
        _authorizeAndDeposit(user1, 1000e18);
        // user2 and user3 authorized but never deposited => zero principal => skipped
        vm.startPrank(owner);
        strategy.setClient(user2, true);
        strategy.setClient(user3, true);
        vm.stopPrank();

        erc4626Vault.simulateYield(100e18);

        uint256 redeemsBefore = erc4626Vault.redeemCount();

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        // Still exactly one redeem (only user1 had surplus)
        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 1, "one redeem despite zero-surplus clients");
        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
    }

    /// @notice No-op (no redeem) when there is no surplus at all
    function testSkimSurplusNoSurplusNoRedeem() public {
        _authorizeAndDeposit(user1, 1000e18);

        uint256 redeemsBefore = erc4626Vault.redeemCount();

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 0, "no redeem when no surplus");
    }

    /// @notice Skim result matches the SNAPSHOT sum (single redeem on a one-shot read)
    function testSkimSurplusUsesSnapshot() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 1000e18);
        erc4626Vault.simulateYield(200e18);

        uint256 snapSurplus1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        uint256 snapSurplus2 = strategy.totalBalanceOf(address(underlyingToken), user2)
            - strategy.principalOf(address(underlyingToken), user2);
        uint256 snapshotSum = snapSurplus1 + snapSurplus2;

        uint256 beforeBal = underlyingToken.balanceOf(withdrawer);
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);
        uint256 received = underlyingToken.balanceOf(withdrawer) - beforeBal;

        assertApproxEqAbs(received, snapshotSum, 5, "skim == snapshot sum");
    }

    // ---- return value (actual underlying received) ----

    /// @notice skimSurplus returns the actual underlying delivered to the recipient (balance delta)
    function testSkimSurplusReturnsUnderlyingReceived() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 3000e18);

        erc4626Vault.simulateYield(800e18);

        uint256 recipientBefore = underlyingToken.balanceOf(withdrawer);

        vm.prank(withdrawer);
        uint256 returned = strategy.skimSurplus(address(underlyingToken), withdrawer);

        uint256 delta = underlyingToken.balanceOf(withdrawer) - recipientBefore;
        assertGt(returned, 0, "non-zero surplus should return non-zero");
        assertEq(returned, delta, "return value == actual underlying delivered to recipient");
    }

    /// @notice skimSurplus returns 0 when there is no surplus (no-op path)
    function testSkimSurplusReturnsZeroOnNoSurplus() public {
        _authorizeAndDeposit(user1, 1000e18);

        vm.prank(withdrawer);
        uint256 returned = strategy.skimSurplus(address(underlyingToken), withdrawer);

        assertEq(returned, 0, "no surplus => returns 0");
    }

    /// @notice skimSurplus returns 0 when nothing has been deposited (totalDeposited == 0)
    function testSkimSurplusReturnsZeroWhenNoDeposits() public {
        erc4626Vault.simulateYield(500e18); // yield but zero principal tracked

        vm.prank(withdrawer);
        uint256 returned = strategy.skimSurplus(address(underlyingToken), withdrawer);

        assertEq(returned, 0, "no deposits => returns 0");
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

    // ============ setAsideBuffer (per-client) TESTS ============

    event SetAsideBufferSet(address indexed client, uint256 oldPercent, uint256 newPercent);

    /// @notice Default buffer is 0 for any client
    function testSetAsideBufferDefaultsZero() public view {
        assertEq(strategy.setAsideBufferSize(user1), 0);
        assertEq(strategy.setAsideBufferSize(client), 0);
    }

    /// @notice Owner can set a buffer; event emitted with old/new
    function testSetSetAsideBufferOwnerAndEvent() public {
        vm.expectEmit(true, false, false, true);
        emit SetAsideBufferSet(user1, 0, 25);
        vm.prank(owner);
        strategy.setSetAsideBuffer(user1, 25);
        assertEq(strategy.setAsideBufferSize(user1), 25);
    }

    /// @notice Non-owner cannot set a buffer
    function testSetSetAsideBufferRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        strategy.setSetAsideBuffer(user1, 25);
    }

    /// @notice Buffer percent > 100 reverts
    function testSetSetAsideBufferRevertsAbove100() public {
        vm.expectRevert("AYieldStrategy: buffer percent exceeds 100");
        vm.prank(owner);
        strategy.setSetAsideBuffer(user1, 101);
    }

    /// @notice Zero client reverts
    function testSetSetAsideBufferRevertsZeroClient() public {
        vm.expectRevert("AYieldStrategy: client cannot be zero address");
        vm.prank(owner);
        strategy.setSetAsideBuffer(address(0), 10);
    }

    /// @notice Buffer 0 (default) => recipient gets full proceeds, return unchanged (regression)
    function testSkimSurplusBufferZeroFullToRecipient() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 3000e18);
        erc4626Vault.simulateYield(800e18);

        uint256 recipientBefore = underlyingToken.balanceOf(withdrawer);
        uint256 client1Before = underlyingToken.balanceOf(user1);

        vm.prank(withdrawer);
        uint256 returned = strategy.skimSurplus(address(underlyingToken), withdrawer);

        uint256 delta = underlyingToken.balanceOf(withdrawer) - recipientBefore;
        assertEq(returned, delta, "return == delivered to recipient");
        assertGt(returned, 0);
        // Clients receive nothing back when buffer is 0
        assertEq(underlyingToken.balanceOf(user1), client1Before, "no set-aside at buffer 0");
    }

    /// @notice Buffer N% for one client: bufferRecipient receives ~N% of that client's proportional
    ///         proceeds as an aggregate transfer, the skim recipient gets the rest. Exactly one redeem.
    function testSkimSurplusBufferSingleClient() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 3000e18);
        erc4626Vault.simulateYield(800e18); // 4000 -> 4800, 800 surplus

        // user1 buffer = 40%
        vm.startPrank(owner);
        strategy.setSetAsideBuffer(user1, 40);
        strategy.setSetAsideBufferRecipient(bufferRecipient);
        vm.stopPrank();

        // Compute user1's snapshot surplus and expected set-aside ~ 40% of user1's proportional proceeds
        uint256 surplus1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);

        uint256 recipientBefore = underlyingToken.balanceOf(withdrawer);
        uint256 bufferRecipientBefore = underlyingToken.balanceOf(bufferRecipient);
        uint256 client1Before = underlyingToken.balanceOf(user1);
        uint256 redeemsBefore = erc4626Vault.redeemCount();

        vm.prank(withdrawer);
        uint256 returned = strategy.skimSurplus(address(underlyingToken), withdrawer);

        // Exactly one redeem in the buffered path
        assertEq(erc4626Vault.redeemCount() - redeemsBefore, 1, "buffered path: exactly one redeem");

        uint256 bufferGot = underlyingToken.balanceOf(bufferRecipient) - bufferRecipientBefore;
        uint256 recipientGot = underlyingToken.balanceOf(withdrawer) - recipientBefore;

        // bufferRecipient received ~40% of user1's surplus (1:1 vault, small rounding dust)
        assertApproxEqAbs(bufferGot, surplus1 * 40 / 100, 5, "bufferRecipient set-aside ~ 40% of user1's surplus");
        assertGt(bufferGot, 0);
        // user1 itself receives nothing (buffer goes to recipient, not back to client)
        assertEq(underlyingToken.balanceOf(user1), client1Before, "client receives nothing back");
        // return value equals what skim recipient actually received
        assertEq(returned, recipientGot, "return == recipient delivered");
        // recipient + buffer set-aside ~= total proceeds
        assertApproxEqAbs(recipientGot + bufferGot, surplus1 + (surplus1 * 3), 6, "split sums to total proceeds");

        // Principal untouched
        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
        assertEq(strategy.principalOf(address(underlyingToken), user2), 3000e18);
    }

    /// @notice Multiple clients with different buffers: aggregate goes to bufferRecipient, clients get nothing
    function testSkimSurplusBufferMultipleClients() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 1000e18);
        _authorizeAndDeposit(user3, 1000e18);
        erc4626Vault.simulateYield(300e18); // 3000 -> 3300, ~100 surplus each

        vm.startPrank(owner);
        strategy.setSetAsideBuffer(user1, 50);
        strategy.setSetAsideBuffer(user2, 25);
        // user3 left at 0
        strategy.setSetAsideBufferRecipient(bufferRecipient);
        vm.stopPrank();

        uint256 s1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        uint256 s2 = strategy.totalBalanceOf(address(underlyingToken), user2)
            - strategy.principalOf(address(underlyingToken), user2);

        uint256 c1Before = underlyingToken.balanceOf(user1);
        uint256 c2Before = underlyingToken.balanceOf(user2);
        uint256 c3Before = underlyingToken.balanceOf(user3);
        uint256 bufferRecipientBefore = underlyingToken.balanceOf(bufferRecipient);

        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);

        // Clients receive nothing back (buffer goes to global recipient)
        assertEq(underlyingToken.balanceOf(user1) - c1Before, 0, "user1 receives nothing back");
        assertEq(underlyingToken.balanceOf(user2) - c2Before, 0, "user2 receives nothing back");
        assertEq(underlyingToken.balanceOf(user3) - c3Before, 0, "user3 buffer 0 -> nothing");

        // bufferRecipient receives the aggregate of user1 (50%) + user2 (25%) set-asides
        uint256 bufferGot = underlyingToken.balanceOf(bufferRecipient) - bufferRecipientBefore;
        uint256 expectedAggregate = s1 * 50 / 100 + s2 * 25 / 100;
        assertApproxEqAbs(bufferGot, expectedAggregate, 10, "bufferRecipient gets aggregate of user1+user2 set-asides");
        assertGt(bufferGot, 0, "some buffer was transferred");
    }

    /// @notice Buffer 100% => that client's whole portion goes to bufferRecipient, not back to client
    function testSkimSurplusBuffer100Percent() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 1000e18);
        erc4626Vault.simulateYield(400e18); // 2000 -> 2400, 200 surplus each

        vm.startPrank(owner);
        strategy.setSetAsideBuffer(user1, 100);
        strategy.setSetAsideBufferRecipient(bufferRecipient);
        vm.stopPrank();

        // Snapshot both surpluses BEFORE the skim (they are consumed by it)
        uint256 s1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        uint256 s2 = strategy.totalBalanceOf(address(underlyingToken), user2)
            - strategy.principalOf(address(underlyingToken), user2);

        uint256 c1Before = underlyingToken.balanceOf(user1);
        uint256 recipientBefore = underlyingToken.balanceOf(withdrawer);
        uint256 bufferRecipientBefore = underlyingToken.balanceOf(bufferRecipient);

        vm.prank(withdrawer);
        uint256 returned = strategy.skimSurplus(address(underlyingToken), withdrawer);

        // user1 gets nothing back (buffer goes to bufferRecipient)
        assertEq(underlyingToken.balanceOf(user1) - c1Before, 0, "client receives nothing back");
        // bufferRecipient gets ~user1's full surplus
        uint256 bufferGot = underlyingToken.balanceOf(bufferRecipient) - bufferRecipientBefore;
        assertApproxEqAbs(bufferGot, s1, 5, "bufferRecipient gets 100% of user1's surplus");
        uint256 recipientGot = underlyingToken.balanceOf(withdrawer) - recipientBefore;
        assertEq(returned, recipientGot, "return == recipient delivered");
        // skim recipient receives ~ user2's surplus only
        assertApproxEqAbs(recipientGot, s2, 6, "skim recipient gets only the non-buffered client surplus");
    }

    /// @notice Front-running: a large fresh deposit before a skim shifts buffer attribution toward
    ///         the depositing client. Documents the accepted economic quirk (not a failure).
    function testSkimSurplusBufferFrontRunShiftsAttribution() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 1000e18);

        // user1 has a 100% buffer; set the global recipient
        vm.startPrank(owner);
        strategy.setSetAsideBuffer(user1, 100);
        strategy.setSetAsideBufferRecipient(bufferRecipient);
        vm.stopPrank();

        // yield accrues
        erc4626Vault.simulateYield(400e18);

        // Baseline: user1's set-aside under equal principals
        uint256 s1Before = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);

        // user1 front-runs with a big fresh deposit, raising its principal-weighted share
        underlyingToken.mint(user1, 5000e18);
        vm.startPrank(user1);
        underlyingToken.approve(address(strategy), type(uint256).max);
        strategy.deposit(address(underlyingToken), 5000e18, user1);
        vm.stopPrank();

        uint256 s1After = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);

        // The fresh deposit increased user1's attributed surplus (and thus its 100% set-aside)
        assertGt(s1After, s1Before, "front-run raises depositing client's attributed surplus");
    }

    // ============ setAsideBufferRecipient TESTS (story 047) ============

    event SetAsideBufferRecipientSet(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Default bufferRecipient is address(0) (unset)
    function testSetAsideBufferRecipientDefaultsZero() public view {
        assertEq(strategy.setAsideBufferRecipient(), address(0));
    }

    /// @notice Owner can set the bufferRecipient; event emitted with old/new
    function testSetSetAsideBufferRecipientOwnerAndEvent() public {
        vm.expectEmit(true, true, false, false);
        emit SetAsideBufferRecipientSet(address(0), bufferRecipient);
        vm.prank(owner);
        strategy.setSetAsideBufferRecipient(bufferRecipient);
        assertEq(strategy.setAsideBufferRecipient(), bufferRecipient);
    }

    /// @notice Non-owner cannot set the bufferRecipient
    function testSetSetAsideBufferRecipientRevertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", randomUser));
        vm.prank(randomUser);
        strategy.setSetAsideBufferRecipient(bufferRecipient);
    }

    /// @notice Zero address reverts
    function testSetSetAsideBufferRecipientRevertsZeroAddress() public {
        vm.expectRevert("AYieldStrategy: recipient cannot be zero address");
        vm.prank(owner);
        strategy.setSetAsideBufferRecipient(address(0));
    }

    /// @notice Skim with nonzero buffer % but unset recipient reverts loudly
    function testSkimSurplusBufferSetButRecipientUnsetReverts() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 1000e18);
        erc4626Vault.simulateYield(200e18);

        // Set a buffer but do NOT set the recipient
        vm.prank(owner);
        strategy.setSetAsideBuffer(user1, 20);

        vm.expectRevert("AYieldStrategy: setAsideBufferRecipient not set");
        vm.prank(withdrawer);
        strategy.skimSurplus(address(underlyingToken), withdrawer);
    }

    /// @notice Skim with all buffer sizes 0 and unset recipient succeeds (back-compat)
    function testSkimSurplusAllBuffersZeroUnsetRecipientSucceeds() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 1000e18);
        erc4626Vault.simulateYield(200e18);

        // No buffer set, no recipient set — should succeed as before
        uint256 recipientBefore = underlyingToken.balanceOf(withdrawer);

        vm.prank(withdrawer);
        uint256 returned = strategy.skimSurplus(address(underlyingToken), withdrawer);

        assertGt(returned, 0, "skim succeeded with no buffers configured");
        assertEq(underlyingToken.balanceOf(withdrawer) - recipientBefore, returned, "recipient got full proceeds");
    }

    /// @notice Multi-client skim: two clients with positive surplus and nonzero buffer;
    ///         bufferRecipient receives the SUM of both buffers, claimer gets the remainder.
    function testSkimSurplusMultiClientBothBuffered() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 2000e18);
        erc4626Vault.simulateYield(600e18); // 3000 -> 3600, surplus proportional

        vm.startPrank(owner);
        strategy.setSetAsideBuffer(user1, 10);
        strategy.setSetAsideBuffer(user2, 10);
        strategy.setSetAsideBufferRecipient(bufferRecipient);
        vm.stopPrank();

        uint256 s1 = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        uint256 s2 = strategy.totalBalanceOf(address(underlyingToken), user2)
            - strategy.principalOf(address(underlyingToken), user2);

        uint256 expectedBuffer1 = s1 * 10 / 100;
        uint256 expectedBuffer2 = s2 * 10 / 100;
        uint256 expectedTotalBuffer = expectedBuffer1 + expectedBuffer2;

        uint256 recipientBefore = underlyingToken.balanceOf(withdrawer);
        uint256 bufferRecipientBefore = underlyingToken.balanceOf(bufferRecipient);

        vm.prank(withdrawer);
        uint256 returned = strategy.skimSurplus(address(underlyingToken), withdrawer);

        uint256 bufferGot = underlyingToken.balanceOf(bufferRecipient) - bufferRecipientBefore;
        uint256 recipientGot = underlyingToken.balanceOf(withdrawer) - recipientBefore;

        // bufferRecipient gets sum of both clients' set-asides
        assertApproxEqAbs(bufferGot, expectedTotalBuffer, 10, "bufferRecipient gets sum of both set-asides");
        assertGt(bufferGot, 0, "nonzero buffer transferred to recipient");

        // claimer gets the remainder
        assertEq(returned, recipientGot, "return == delivered to claimer");
        assertApproxEqAbs(recipientGot + bufferGot, s1 + s2, 10, "total split = total surplus");

        // Principal unchanged
        assertEq(strategy.principalOf(address(underlyingToken), user1), 1000e18);
        assertEq(strategy.principalOf(address(underlyingToken), user2), 2000e18);
    }

    // ============ relinquishPrincipal TESTS (story 045) ============

    /// @dev Local copy of the event for vm.expectEmit matching.
    event PrincipalRelinquished(address indexed token, address indexed client, uint256 amount, uint256 newPrincipal);

    /// @notice Happy path: relinquishing part of principal drops principalOf and getTotalDeposited
    ///         by exactly `amount`.
    function testRelinquishPrincipalHappyPath() public {
        _authorizeAndDeposit(user1, 1000e18);

        uint256 principalBefore = strategy.principalOf(address(underlyingToken), user1);
        uint256 totalBefore = strategy.getTotalDeposited(address(underlyingToken));
        uint256 relinquish = 400e18;

        vm.prank(user1);
        strategy.relinquishPrincipal(address(underlyingToken), relinquish);

        assertEq(
            strategy.principalOf(address(underlyingToken), user1),
            principalBefore - relinquish,
            "principal drops exactly"
        );
        assertEq(
            strategy.getTotalDeposited(address(underlyingToken)),
            totalBefore - relinquish,
            "totalDeposited drops exactly"
        );
    }

    /// @notice Shares are untouched by relinquish: getTotalShares and vault.balanceOf identical.
    function testRelinquishPrincipalDoesNotTouchShares() public {
        _authorizeAndDeposit(user1, 1000e18);

        uint256 sharesBefore = strategy.getTotalShares();
        uint256 vaultBalBefore = erc4626Vault.balanceOf(address(strategy));

        vm.prank(user1);
        strategy.relinquishPrincipal(address(underlyingToken), 400e18);

        assertEq(strategy.getTotalShares(), sharesBefore, "getTotalShares unchanged");
        assertEq(erc4626Vault.balanceOf(address(strategy)), vaultBalBefore, "vault share balance unchanged");
    }

    /// @notice Invariant totalDeposited == Σ clientBalances holds after relinquish, single & multi client.
    function testRelinquishPrincipalPreservesInvariant() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 2000e18);

        vm.prank(user1);
        strategy.relinquishPrincipal(address(underlyingToken), 300e18);

        uint256 sumBalances = strategy.principalOf(address(underlyingToken), user1)
            + strategy.principalOf(address(underlyingToken), user2);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), sumBalances, "invariant holds multi-client");

        // Now drive single-client: relinquish all of user2
        vm.prank(user2);
        strategy.relinquishPrincipal(address(underlyingToken), 2000e18);
        sumBalances = strategy.principalOf(address(underlyingToken), user1)
            + strategy.principalOf(address(underlyingToken), user2);
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), sumBalances, "invariant holds after second");
    }

    /// @notice Underwater -> relinquish dormant principal -> recovery -> recovered value flows to yield.
    function testRelinquishUnderwaterThenRecoveryFlowsToYield() public {
        // Single principal client (the stable-staker model)
        _authorizeAndDeposit(user1, 1000e18);

        // Vault goes underwater: lose 400 of the 1000 deposited
        erc4626Vault.simulateLoss(400e18);

        // No surplus exists while underwater
        assertEq(strategy.totalBalanceOf(address(underlyingToken), user1), 600e18, "underwater value < principal");

        // Client relinquishes the dormant 400 of principal (already covered by its buffer)
        vm.prank(user1);
        strategy.relinquishPrincipal(address(underlyingToken), 400e18);

        assertEq(strategy.getTotalDeposited(address(underlyingToken)), 600e18, "totalDeposited written down");

        // Vault recovers back to 1000 of value (add 400 back)
        erc4626Vault.simulateYield(400e18);

        // The recovered value above the now-smaller principal is skimmable surplus
        uint256 surplus = strategy.totalBalanceOf(address(underlyingToken), user1)
            - strategy.principalOf(address(underlyingToken), user1);
        assertApproxEqAbs(surplus, 400e18, 2, "recovered value now appears as surplus, not principal");

        uint256 recipientBefore = underlyingToken.balanceOf(withdrawer);
        vm.prank(withdrawer);
        uint256 skimmed = strategy.skimSurplus(address(underlyingToken), withdrawer);
        assertApproxEqAbs(skimmed, 400e18, 2, "skim returns the recovered (now-yield) value");
        assertApproxEqAbs(
            underlyingToken.balanceOf(withdrawer) - recipientBefore, 400e18, 2, "recipient received the recovered value"
        );
    }

    /// @notice Over-request is capped to available principal (no revert); principal floors at 0; shares untouched.
    function testRelinquishPrincipalOverRequestCapped() public {
        _authorizeAndDeposit(user1, 1000e18);

        uint256 sharesBefore = strategy.getTotalShares();

        vm.prank(user1);
        strategy.relinquishPrincipal(address(underlyingToken), 5000e18); // way more than available

        assertEq(strategy.principalOf(address(underlyingToken), user1), 0, "principal floors at 0");
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), 0, "totalDeposited floors at 0");
        assertEq(strategy.getTotalShares(), sharesBefore, "shares untouched on over-request");
    }

    /// @notice Reverts: amount == 0.
    function testRelinquishPrincipalRevertsZeroAmount() public {
        _authorizeAndDeposit(user1, 1000e18);
        vm.prank(user1);
        vm.expectRevert("AYieldStrategy: amount must be greater than zero");
        strategy.relinquishPrincipal(address(underlyingToken), 0);
    }

    /// @notice Reverts: wrong token.
    function testRelinquishPrincipalRevertsWrongToken() public {
        _authorizeAndDeposit(user1, 1000e18);
        vm.prank(user1);
        vm.expectRevert("AYieldStrategy: only underlying token supported");
        strategy.relinquishPrincipal(address(0xBAD), 100e18);
    }

    /// @notice Reverts: caller not an authorized client.
    function testRelinquishPrincipalRevertsUnauthorized() public {
        vm.prank(randomUser);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        strategy.relinquishPrincipal(address(underlyingToken), 100e18);
    }

    /// @notice Works while paused (not whenNotPaused-gated).
    function testRelinquishPrincipalWorksWhilePaused() public {
        _authorizeAndDeposit(user1, 1000e18);

        vm.prank(pauser);
        strategy.pause();

        vm.prank(user1);
        strategy.relinquishPrincipal(address(underlyingToken), 400e18);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 600e18, "relinquish succeeded while paused");
    }

    /// @notice PrincipalRelinquished event emitted with correct (token, client, amount, newPrincipal).
    function testRelinquishPrincipalEmitsEvent() public {
        _authorizeAndDeposit(user1, 1000e18);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit PrincipalRelinquished(address(underlyingToken), user1, 400e18, 600e18);

        vm.prank(user1);
        strategy.relinquishPrincipal(address(underlyingToken), 400e18);
    }

    // ---- Owner variant ----

    /// @notice relinquishPrincipalAsOwner writes down the named client's principal (not the owner's).
    function testRelinquishPrincipalAsOwnerWritesDownNamedClient() public {
        _authorizeAndDeposit(user1, 1000e18);

        uint256 sharesBefore = strategy.getTotalShares();

        vm.prank(owner);
        strategy.relinquishPrincipalAsOwner(user1, 400e18);

        assertEq(strategy.principalOf(address(underlyingToken), user1), 600e18, "named client written down");
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), 600e18, "totalDeposited written down");
        assertEq(strategy.getTotalShares(), sharesBefore, "shares untouched");
    }

    /// @notice relinquishPrincipalAsOwner reverts when caller is not the owner.
    function testRelinquishPrincipalAsOwnerRevertsNotOwner() public {
        _authorizeAndDeposit(user1, 1000e18);
        vm.prank(randomUser);
        vm.expectRevert();
        strategy.relinquishPrincipalAsOwner(user1, 400e18);
    }

    /// @notice relinquishPrincipalAsOwner caps over-requests and emits the event identically.
    function testRelinquishPrincipalAsOwnerCapsAndEmits() public {
        _authorizeAndDeposit(user1, 1000e18);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit PrincipalRelinquished(address(underlyingToken), user1, 1000e18, 0);

        vm.prank(owner);
        strategy.relinquishPrincipalAsOwner(user1, 5000e18); // over-request

        assertEq(strategy.principalOf(address(underlyingToken), user1), 0, "capped to available");
        assertEq(strategy.getTotalDeposited(address(underlyingToken)), 0, "totalDeposited floored");
    }

    // ============ EXIT PREVIEW TESTS (story 050) ============
    // ERC4626YieldStrategy deliberately supplies NO override of previewExitFor: its _disposeShares
    // applies no bps haircut and no minOut, so AYieldStrategy's capped-identity default is already
    // the correct answer. These tests pin that default down through the concrete.

    /// @notice The default preview is the identity: request exactly what you want, get it guaranteed.
    function testPreviewExitForIsIdentityOnDirectStrategy() public {
        _authorizeAndDeposit(user1, 1000e18);

        (uint256 grossToRequest, uint256 netGuaranteed) =
            strategy.previewExitFor(address(underlyingToken), user1, 400e18);

        assertEq(grossToRequest, 400e18, "no haircut on a direct strategy");
        assertEq(netGuaranteed, 400e18, "gross and net coincide");
        assertEq(grossToRequest, netGuaranteed, "identity: grossToRequest == netGuaranteed");
    }

    /// @notice The default replicates _withdrawInternal's per-account cap exactly.
    function testPreviewExitForCapsToAccountPrincipal() public {
        _authorizeAndDeposit(user1, 1000e18);

        (uint256 grossToRequest, uint256 netGuaranteed) =
            strategy.previewExitFor(address(underlyingToken), user1, 2500e18);

        assertEq(grossToRequest, 1000e18, "capped to clientBalances[token][account]");
        assertEq(netGuaranteed, 1000e18);
    }

    /// @notice The cap is per-ACCOUNT, not per-strategy: another depositor's principal is not visible.
    function testPreviewExitForCapIsPerAccountNotGlobal() public {
        _authorizeAndDeposit(user1, 1000e18);
        _authorizeAndDeposit(user2, 4000e18);

        (uint256 grossToRequest,) = strategy.previewExitFor(address(underlyingToken), user1, 5000e18);
        assertEq(grossToRequest, 1000e18, "user1 is capped to user1's own principal");

        (uint256 grossToRequest2,) = strategy.previewExitFor(address(underlyingToken), user2, 5000e18);
        assertEq(grossToRequest2, 4000e18, "user2 is capped to user2's own principal");
    }

    /// @notice An account with no principal quotes zero rather than reverting.
    function testPreviewExitForUnknownAccountReturnsZero() public view {
        (uint256 grossToRequest, uint256 netGuaranteed) =
            strategy.previewExitFor(address(underlyingToken), randomUser, 100e18);

        assertEq(grossToRequest, 0);
        assertEq(netGuaranteed, 0);
    }

    /// @notice Only the underlying token is previewable.
    function testPreviewExitForRevertsForWrongToken() public {
        vm.expectRevert("AYieldStrategy: only underlying token supported");
        strategy.previewExitFor(address(erc4626Vault), user1, 100e18);
    }

    /// @notice Round trip: a preview followed by the withdrawal it sizes delivers at least the floor.
    function testPreviewExitForRoundTripDeliversAtLeastFloor() public {
        _authorizeAndDeposit(user1, 1000e18);

        (uint256 grossToRequest, uint256 netGuaranteed) =
            strategy.previewExitFor(address(underlyingToken), user1, 400e18);

        uint256 balanceBefore = underlyingToken.balanceOf(user1);
        vm.prank(user1);
        strategy.withdraw(address(underlyingToken), grossToRequest, user1);
        uint256 delivered = underlyingToken.balanceOf(user1) - balanceBefore;

        assertGe(delivered, netGuaranteed, "delivery must never fall below the quoted floor");
    }

    /// @notice STATICCALL safety (story 049 carried forward): previewExitFor must survive a static
    ///         frame even when the wrapped vault's `previewRedeem` mutates state, proving it is built
    ///         on convertToShares/convertToAssets and never touches previewRedeem/previewWithdraw or
    ///         the strategy's own previewRedeem wrapper.
    function testPreviewExitFor_StateChangingPreviewRedeemVault_SurvivesStaticcall() public {
        MockStateChangingPreviewVault scVault =
            new MockStateChangingPreviewVault("SC Vault", "scV", address(underlyingToken));
        vm.prank(owner);
        ERC4626YieldStrategy scStrategy = new ERC4626YieldStrategy(owner, address(underlyingToken), address(scVault));

        vm.prank(owner);
        scStrategy.setClient(client, true);
        vm.prank(client);
        underlyingToken.approve(address(scStrategy), type(uint256).max);

        vm.prank(client);
        scStrategy.deposit(address(underlyingToken), 1000e18, client);
        scVault.simulateYield(500e18); // non-1:1 ratio, so the conversions are not trivial identities

        // Control: the vault's previewRedeem really is STATICCALL-hostile.
        (bool prOk,) = address(scVault).staticcall(abi.encodeWithSignature("previewRedeem(uint256)", uint256(1e18)));
        assertFalse(prOk, "mock vault's previewRedeem must trap under STATICCALL");

        // The preview itself must nonetheless succeed under a static frame.
        (bool ok, bytes memory data) = address(scStrategy)
            .staticcall(
                abi.encodeWithSignature(
                    "previewExitFor(address,address,uint256)", address(underlyingToken), client, 400e18
                )
            );
        assertTrue(ok, "previewExitFor must be STATICCALL-safe against an Autopool-style vault");

        (uint256 grossToRequest, uint256 netGuaranteed) = abi.decode(data, (uint256, uint256));
        assertEq(grossToRequest, 400e18, "identity default holds on the direct strategy");
        assertEq(netGuaranteed, 400e18);
    }
}
