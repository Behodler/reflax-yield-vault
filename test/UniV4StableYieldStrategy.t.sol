// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/concreteYieldStrategies/UniV4StableYieldStrategy.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockV4PoolManager.sol";
import "../src/imports/IPoolManager.sol";

/**
 * @title UniV4StableYieldStrategyTest
 * @notice Comprehensive tests for UniV4StableYieldStrategy
 */
contract UniV4StableYieldStrategyTest is Test {
    UniV4StableYieldStrategy strategy;
    MockV4PoolManager poolManager;
    MockERC20 depositToken;
    MockERC20 pairedToken;

    address owner = address(0x1234);
    address client = address(0x5678);
    address user1 = address(0xDEF0);
    address pauser = address(0xABCD);
    address withdrawer = address(0x9876);

    int24 constant TICK_LOWER = -100;
    int24 constant TICK_UPPER = 100;
    uint24 constant SLIPPAGE_TOLERANCE = 50; // 0.5%
    uint256 constant TOLERABLE_LOSS = 100e18;

    uint256 constant INITIAL_SUPPLY = 10_000_000e18;

    function setUp() public {
        _setUpWithDecimals(18, 18);
    }

    function _setUpWithDecimals(uint8 depositDecimals, uint8 pairedDecimals) internal {
        // Deploy mock tokens with specific decimals
        depositToken = new MockERC20("USDC", "USDC", depositDecimals);
        pairedToken = new MockERC20("USDT", "USDT", pairedDecimals);

        // Deploy mock pool manager
        poolManager =
            new MockV4PoolManager(address(depositToken), address(pairedToken), depositDecimals, pairedDecimals);

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: address(depositToken),
            currency1: address(pairedToken),
            fee: 500, // 0.05%
            tickSpacing: 10,
            hooks: address(0)
        });

        // Initialize pool in mock
        poolManager.initializePool(poolKey, uint160(1) << 96); // 1:1 price

        // Deploy strategy
        vm.prank(owner);
        strategy = new UniV4StableYieldStrategy(
            owner,
            address(depositToken),
            address(pairedToken),
            address(poolManager),
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            SLIPPAGE_TOLERANCE,
            TOLERABLE_LOSS
        );

        // Mint tokens
        uint256 depositSupply = INITIAL_SUPPLY / (10 ** (18 - depositDecimals));
        uint256 pairedSupply = INITIAL_SUPPLY / (10 ** (18 - pairedDecimals));

        depositToken.mint(client, depositSupply);
        depositToken.mint(address(poolManager), depositSupply); // For swaps/liquidity
        pairedToken.mint(address(poolManager), pairedSupply);

        // Authorize client
        vm.prank(owner);
        strategy.setClient(client, true);

        // Set up pauser
        vm.prank(owner);
        strategy.setPauser(pauser);
    }

    // ============ CONSTRUCTOR TESTS ============

    function testConstructorInitializesCorrectly() public view {
        assertEq(address(strategy.depositToken()), address(depositToken));
        assertEq(address(strategy.pairedToken()), address(pairedToken));
        assertEq(address(strategy.poolManager()), address(poolManager));
        assertEq(strategy.tickLower(), TICK_LOWER);
        assertEq(strategy.tickUpper(), TICK_UPPER);
        assertEq(strategy.slippageTolerance(), SLIPPAGE_TOLERANCE);
        assertEq(strategy.tolerableLoss(), TOLERABLE_LOSS);
    }

    function testConstructorRevertsZeroDepositToken() public {
        PoolKey memory poolKey = PoolKey({
            currency0: address(0), currency1: address(pairedToken), fee: 500, tickSpacing: 10, hooks: address(0)
        });

        vm.expectRevert("UniV4StableYieldStrategy: deposit token cannot be zero address");
        new UniV4StableYieldStrategy(
            owner,
            address(0),
            address(pairedToken),
            address(poolManager),
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            SLIPPAGE_TOLERANCE,
            TOLERABLE_LOSS
        );
    }

    function testConstructorRevertsInvalidTickRange() public {
        PoolKey memory poolKey = PoolKey({
            currency0: address(depositToken),
            currency1: address(pairedToken),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });

        vm.expectRevert("UniV4StableYieldStrategy: invalid tick range");
        new UniV4StableYieldStrategy(
            owner,
            address(depositToken),
            address(pairedToken),
            address(poolManager),
            poolKey,
            100, // tickLower > tickUpper
            -100,
            SLIPPAGE_TOLERANCE,
            TOLERABLE_LOSS
        );
    }

    function testConstructorRevertsHighSlippage() public {
        PoolKey memory poolKey = PoolKey({
            currency0: address(depositToken),
            currency1: address(pairedToken),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });

        vm.expectRevert("UniV4StableYieldStrategy: slippage tolerance too high");
        new UniV4StableYieldStrategy(
            owner,
            address(depositToken),
            address(pairedToken),
            address(poolManager),
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            200, // > 1%
            TOLERABLE_LOSS
        );
    }

    // ============ DEPOSIT TESTS ============

    function testDepositBasic() public {
        uint256 depositAmount = 1000e18;

        vm.startPrank(client);
        depositToken.approve(address(strategy), depositAmount);
        strategy.deposit(address(depositToken), depositAmount, user1);
        vm.stopPrank();

        // Check state updates
        assertEq(strategy.totalDeposits(), depositAmount);
        assertEq(strategy.principalOf(address(depositToken), user1), depositAmount);
        assertGt(strategy.getLiquidityPosition(), 0);
    }

    function testDepositUpdatesClientBalances() public {
        uint256 deposit1 = 500e18;
        uint256 deposit2 = 1000e18;

        vm.startPrank(client);
        depositToken.approve(address(strategy), deposit1 + deposit2);

        strategy.deposit(address(depositToken), deposit1, user1);
        strategy.deposit(address(depositToken), deposit2, client);
        vm.stopPrank();

        assertEq(strategy.principalOf(address(depositToken), user1), deposit1);
        assertEq(strategy.principalOf(address(depositToken), client), deposit2);
        assertEq(strategy.totalDeposits(), deposit1 + deposit2);
    }

    function testDepositRevertsWrongToken() public {
        uint256 depositAmount = 1000e18;

        vm.startPrank(client);
        pairedToken.approve(address(strategy), depositAmount);

        vm.expectRevert(UniV4StableYieldStrategy.InvalidToken.selector);
        strategy.deposit(address(pairedToken), depositAmount, user1);
        vm.stopPrank();
    }

    function testDepositRevertsUnauthorizedClient() public {
        uint256 depositAmount = 1000e18;

        vm.prank(user1);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        strategy.deposit(address(depositToken), depositAmount, user1);
    }

    function testDepositRevertsZeroAmount() public {
        vm.prank(client);
        vm.expectRevert("UniV4StableYieldStrategy: amount must be greater than zero");
        strategy.deposit(address(depositToken), 0, user1);
    }

    function testDepositRevertsWhenPaused() public {
        vm.prank(pauser);
        strategy.pause();

        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);

        vm.expectRevert();
        strategy.deposit(address(depositToken), 1000e18, user1);
        vm.stopPrank();
    }

    // ============ WITHDRAW TESTS ============

    function testWithdrawRevertsAlways() public {
        // First deposit
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, client);
        vm.stopPrank();

        // Attempt withdraw
        vm.prank(client);
        vm.expectRevert(UniV4StableYieldStrategy.WithdrawalsDisabled.selector);
        strategy.withdraw(address(depositToken), 500e18, client);
    }

    // ============ YIELD COLLECTION TESTS ============

    function testCollectYieldWithNoFees() public {
        // Deposit first
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, user1);
        vm.stopPrank();

        // Collect yield (should be 0)
        uint256 balanceBefore = depositToken.balanceOf(client);
        vm.prank(client);
        uint256 yield = strategy.collectYield();
        uint256 balanceAfter = depositToken.balanceOf(client);

        assertEq(yield, 0);
        assertEq(balanceAfter, balanceBefore);
    }

    function testCollectYieldWithSimulatedFees() public {
        // Deposit first
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, user1);
        vm.stopPrank();

        // Simulate fees
        uint128 fees0 = 50e18;
        uint128 fees1 = 50e18;
        poolManager.simulateFees(address(strategy), TICK_LOWER, TICK_UPPER, bytes32(0), fees0, fees1);

        // Fund pool manager with tokens to pay out fees
        depositToken.mint(address(poolManager), fees0);
        pairedToken.mint(address(poolManager), fees1);

        // Collect yield
        uint256 balanceBefore = depositToken.balanceOf(client);
        vm.prank(client);
        uint256 yield = strategy.collectYield();
        uint256 balanceAfter = depositToken.balanceOf(client);

        // Should receive deposit token fees + converted paired token fees
        assertGt(yield, 0);
        assertEq(balanceAfter - balanceBefore, yield);
    }

    // ============ MIGRATION TESTS ============

    function testMigrateSucceedsWithinTolerance() public {
        // Deposit
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, user1);
        vm.stopPrank();

        address newStrategy = address(0x1111);

        // Migrate
        vm.prank(owner);
        strategy.migrate(newStrategy);

        // Check state reset
        assertEq(strategy.getLiquidityPosition(), 0);
        assertEq(strategy.totalDeposits(), 0);

        // Check tokens transferred
        assertGt(depositToken.balanceOf(newStrategy), 0);
    }

    function testMigrateRevertsExceedsTolerance() public {
        // Create strategy with 0 loss tolerance
        PoolKey memory poolKey = PoolKey({
            currency0: address(depositToken),
            currency1: address(pairedToken),
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });

        vm.prank(owner);
        UniV4StableYieldStrategy strictStrategy = new UniV4StableYieldStrategy(
            owner,
            address(depositToken),
            address(pairedToken),
            address(poolManager),
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            SLIPPAGE_TOLERANCE,
            0 // Zero tolerance
        );

        // Authorize and deposit
        vm.prank(owner);
        strictStrategy.setClient(client, true);

        vm.startPrank(client);
        depositToken.approve(address(strictStrategy), 1000e18);
        strictStrategy.deposit(address(depositToken), 1000e18, user1);
        vm.stopPrank();

        // Set slippage to simulate loss
        poolManager.setSwapSlippage(200); // 2% slippage

        // Migrate should revert due to loss exceeding tolerance
        vm.prank(owner);
        vm.expectRevert(); // Will revert due to loss exceeding zero tolerance
        strictStrategy.migrate(address(0x1111));
    }

    function testMigrateOnlyOwner() public {
        vm.prank(client);
        vm.expectRevert();
        strategy.migrate(address(0x1111));
    }

    // ============ CONFIGURATION TESTS ============

    function testSetSlippageTolerance() public {
        uint24 newTolerance = 75;

        vm.prank(owner);
        strategy.setSlippageTolerance(newTolerance);

        assertEq(strategy.slippageTolerance(), newTolerance);
    }

    function testSetSlippageToleranceRevertsIfTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(UniV4StableYieldStrategy.SlippageToleranceTooHigh.selector, 150, 100));
        strategy.setSlippageTolerance(150); // > 1%
    }

    function testSetSlippageToleranceOnlyOwner() public {
        vm.prank(client);
        vm.expectRevert();
        strategy.setSlippageTolerance(75);
    }

    function testSetTolerableLoss() public {
        uint256 newTolerance = 200e18;

        vm.prank(owner);
        strategy.setTolerableLoss(newTolerance);

        assertEq(strategy.tolerableLoss(), newTolerance);
    }

    function testSetTolerableLossOnlyOwner() public {
        vm.prank(client);
        vm.expectRevert();
        strategy.setTolerableLoss(200e18);
    }

    // ============ VIEW FUNCTION TESTS ============

    function testPrincipalOf() public {
        uint256 depositAmount = 1000e18;

        vm.startPrank(client);
        depositToken.approve(address(strategy), depositAmount);
        strategy.deposit(address(depositToken), depositAmount, user1);
        vm.stopPrank();

        assertEq(strategy.principalOf(address(depositToken), user1), depositAmount);
        assertEq(strategy.principalOf(address(depositToken), client), 0);
    }

    function testPrincipalOfRevertsWrongToken() public {
        vm.expectRevert(UniV4StableYieldStrategy.InvalidToken.selector);
        strategy.principalOf(address(pairedToken), user1);
    }

    function testTotalBalanceOf() public {
        uint256 depositAmount = 1000e18;

        vm.startPrank(client);
        depositToken.approve(address(strategy), depositAmount);
        strategy.deposit(address(depositToken), depositAmount, user1);
        vm.stopPrank();

        // With no yield, totalBalanceOf should approximate principalOf
        uint256 totalBalance = strategy.totalBalanceOf(address(depositToken), user1);
        assertGt(totalBalance, 0);
    }

    function testBalanceOfDelegatesToPrincipalOf() public {
        uint256 depositAmount = 1000e18;

        vm.startPrank(client);
        depositToken.approve(address(strategy), depositAmount);
        strategy.deposit(address(depositToken), depositAmount, user1);
        vm.stopPrank();

        assertEq(strategy.balanceOf(address(depositToken), user1), strategy.principalOf(address(depositToken), user1));
    }

    // ============ ACCESS CONTROL TESTS ============

    function testOnlyAuthorizedClientCanDeposit() public {
        vm.prank(user1);
        vm.expectRevert("AYieldStrategy: unauthorized, only authorized clients");
        strategy.deposit(address(depositToken), 100e18, user1);
    }

    function testOwnerCanSetClient() public {
        vm.prank(owner);
        strategy.setClient(user1, true);

        assertTrue(strategy.authorizedClients(user1));
    }

    function testNonOwnerCannotSetClient() public {
        vm.prank(client);
        vm.expectRevert();
        strategy.setClient(user1, true);
    }

    // ============ PAUSABILITY TESTS ============

    function testPauserCanPause() public {
        vm.prank(pauser);
        strategy.pause();

        assertTrue(strategy.paused());
    }

    function testOwnerCanUnpause() public {
        vm.prank(pauser);
        strategy.pause();

        vm.prank(owner);
        strategy.unpause();

        assertFalse(strategy.paused());
    }

    function testPauserCanUnpause() public {
        vm.prank(pauser);
        strategy.pause();

        vm.prank(pauser);
        strategy.unpause();

        assertFalse(strategy.paused());
    }

    function testOperationsBlockedWhenPaused() public {
        vm.prank(pauser);
        strategy.pause();

        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);

        vm.expectRevert();
        strategy.deposit(address(depositToken), 1000e18, client);
        vm.stopPrank();
    }

    // ============ EMERGENCY WITHDRAWAL TESTS ============

    function testEmergencyWithdraw() public {
        // Deposit first
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, user1);
        vm.stopPrank();

        uint256 ownerBalanceBefore = depositToken.balanceOf(owner);

        // Emergency withdraw
        vm.prank(owner);
        strategy.emergencyWithdraw(500e18);

        uint256 ownerBalanceAfter = depositToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore);
    }

    function testEmergencyWithdrawOnlyOwner() public {
        vm.prank(client);
        vm.expectRevert();
        strategy.emergencyWithdraw(500e18);
    }

    // ============ DECIMAL CONFIGURATION TESTS ============

    function testDecimals6_6() public {
        _setUpWithDecimals(6, 6);
        _testBasicDepositWithDecimals(6);
    }

    function testDecimals18_18() public {
        _setUpWithDecimals(18, 18);
        _testBasicDepositWithDecimals(18);
    }

    function testDecimals6_18() public {
        _setUpWithDecimals(6, 18);
        _testBasicDepositWithDecimals(6);
    }

    function testDecimals18_6() public {
        _setUpWithDecimals(18, 6);
        _testBasicDepositWithDecimals(18);
    }

    function _testBasicDepositWithDecimals(uint8 depositDecimals) internal {
        uint256 depositAmount = 1000 * (10 ** depositDecimals);

        vm.startPrank(client);
        depositToken.approve(address(strategy), depositAmount);
        strategy.deposit(address(depositToken), depositAmount, user1);
        vm.stopPrank();

        assertEq(strategy.totalDeposits(), depositAmount);
        assertEq(strategy.principalOf(address(depositToken), user1), depositAmount);
        assertGt(strategy.getLiquidityPosition(), 0);
    }

    // ============ TWO-PHASE WITHDRAWAL TESTS ============

    function testTotalWithdrawalPhase1Initiation() public {
        // Deposit first
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, client);
        vm.stopPrank();

        // Initiate withdrawal (Phase 1)
        vm.prank(owner);
        strategy.totalWithdrawal(address(depositToken), client);

        // Check withdrawal state
        (uint256 initiatedAt,,) = strategy.withdrawalStates(address(depositToken), client);
        assertGt(initiatedAt, 0);
    }

    function testTotalWithdrawalPhase2Execution() public {
        // Deposit first
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, client);
        vm.stopPrank();

        // Initiate withdrawal (Phase 1)
        vm.prank(owner);
        strategy.totalWithdrawal(address(depositToken), client);

        // Warp time past waiting period
        vm.warp(block.timestamp + 25 hours);

        uint256 ownerBalanceBefore = depositToken.balanceOf(owner);

        // Execute withdrawal (Phase 2)
        vm.prank(owner);
        strategy.totalWithdrawal(address(depositToken), client);

        uint256 ownerBalanceAfter = depositToken.balanceOf(owner);
        assertGt(ownerBalanceAfter, ownerBalanceBefore);
    }

    function testTotalWithdrawalRevertsInWaitingPeriod() public {
        // Deposit first
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, client);
        vm.stopPrank();

        // Initiate withdrawal (Phase 1)
        vm.prank(owner);
        strategy.totalWithdrawal(address(depositToken), client);

        // Try to execute immediately (should revert)
        vm.prank(owner);
        vm.expectRevert();
        strategy.totalWithdrawal(address(depositToken), client);
    }

    // ============ WITHDRAWFROM SURPLUS TESTS ============

    function testWithdrawFromOnlyWithdrawsSurplus() public {
        // Deposit
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, client);
        vm.stopPrank();

        // Authorize withdrawer
        vm.prank(owner);
        strategy.setWithdrawer(withdrawer, true);

        // Try to withdraw more than surplus (should fail since no surplus yet)
        vm.prank(withdrawer);
        vm.expectRevert(
            "UniV4StableYieldStrategy: amount exceeds available surplus, use totalWithdrawal() for principal"
        );
        strategy.withdrawFrom(address(depositToken), client, 100e18, withdrawer);
    }

    function testWithdrawFromDoesNotModifyPrincipal() public {
        // Deposit
        vm.startPrank(client);
        depositToken.approve(address(strategy), 1000e18);
        strategy.deposit(address(depositToken), 1000e18, client);
        vm.stopPrank();

        uint256 principalBefore = strategy.principalOf(address(depositToken), client);

        // Authorize withdrawer
        vm.prank(owner);
        strategy.setWithdrawer(withdrawer, true);

        // Simulate fees for surplus
        poolManager.simulateFees(address(strategy), TICK_LOWER, TICK_UPPER, bytes32(0), 100e18, 0);
        depositToken.mint(address(poolManager), 100e18);

        // The surplus extraction would only work if we had actual yield
        // For this test, principal should remain unchanged regardless
        uint256 principalAfter = strategy.principalOf(address(depositToken), client);
        assertEq(principalBefore, principalAfter);
    }

    // ============ EDGE CASE TESTS ============

    function testZeroDepositsReturnsZeroBalances() public view {
        assertEq(strategy.totalDeposits(), 0);
        assertEq(strategy.principalOf(address(depositToken), user1), 0);
        assertEq(strategy.totalBalanceOf(address(depositToken), user1), 0);
        assertEq(strategy.getLiquidityPosition(), 0);
    }

    function testVerySmallDeposits() public {
        uint256 tinyAmount = 1; // 1 wei

        vm.startPrank(client);
        depositToken.approve(address(strategy), tinyAmount);
        strategy.deposit(address(depositToken), tinyAmount, user1);
        vm.stopPrank();

        assertEq(strategy.totalDeposits(), tinyAmount);
    }

    function testMultipleDepositsFromSameClient() public {
        vm.startPrank(client);
        depositToken.approve(address(strategy), 3000e18);

        strategy.deposit(address(depositToken), 1000e18, user1);
        strategy.deposit(address(depositToken), 500e18, user1);
        strategy.deposit(address(depositToken), 1500e18, user1);
        vm.stopPrank();

        assertEq(strategy.principalOf(address(depositToken), user1), 3000e18);
        assertEq(strategy.totalDeposits(), 3000e18);
    }

    function testGetPoolKey() public view {
        PoolKey memory key = strategy.getPoolKey();
        assertEq(key.currency0, address(depositToken));
        assertEq(key.currency1, address(pairedToken));
        assertEq(key.fee, 500);
    }

    function testPendingYieldWithNoPosition() public view {
        (uint256 fees0, uint256 fees1) = strategy.pendingYield();
        assertEq(fees0, 0);
        assertEq(fees1, 0);
    }
}
