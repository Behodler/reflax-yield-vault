// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import "../../src/AMMAdapters/CurveAMMAdapter.sol";
import "../../src/mocks/MockERC20.sol";
import "../mocks/MockRestrictedERC4626Vault.sol";
import "../mocks/MockCurveStableSwapNGPool.sol";
import "../mocks/MockCurveRouterNGRouted.sol";

/**
 * @title ERC4626MarketYieldStrategy_CurveUSDe
 * @notice End-to-end integration test: real `ERC4626MarketYieldStrategy` + real `CurveAMMAdapter`
 *         + route-walking mock router + mock Stableswap-NG pools + restricted mock vault.
 * @dev Mirrors the planned USDe/sUSDe mainnet deployment topology. Uses the exact `route`,
 *      `swapParams`, and `pools` payload from `AMMRoutes.json` so that bugs in the seed data
 *      surface here rather than on mainnet. All tests run locally; no fork required.
 */
contract ERC4626MarketYieldStrategy_CurveUSDe is Test {
    // Core mocks
    MockERC20 usde;
    MockERC20 crvUSD;
    MockRestrictedERC4626Vault sUSDe;

    // Curve mocks
    MockCurveStableSwapNGPool pool1; // USDe/crvUSD (coin0 = USDe, coin1 = crvUSD)
    MockCurveStableSwapNGPool pool2; // sUSDe/crvUSD (coin0 = sUSDe, coin1 = crvUSD)
    MockCurveRouterNGRouted router;

    // Real contracts under test
    CurveAMMAdapter adapter;
    ERC4626MarketYieldStrategy strategy;

    address owner = address(0xA11CE);
    address client = address(0xC711E);
    address user1 = address(0xD1);
    address user2 = address(0xD2);

    uint256 constant POOL_LIQUIDITY = 10_000_000e18;
    uint256 constant CLIENT_INITIAL = 1_000_000e18;

    function setUp() public {
        _deployTokensAndVault();
        _deployPoolsAndRouter();
        _deployStrategyStack();
        _configureRoutes();
        _fundPools();
        _fundClientAndApprove();
    }

    // ============ setUp helpers ============

    function _deployTokensAndVault() internal {
        usde = new MockERC20("USDe", "USDe", 18);
        crvUSD = new MockERC20("crvUSD", "crvUSD", 18);
        sUSDe = new MockRestrictedERC4626Vault(address(usde), "Staked USDe", "sUSDe");
    }

    function _deployPoolsAndRouter() internal {
        pool1 = new MockCurveStableSwapNGPool(address(usde), address(crvUSD));
        pool2 = new MockCurveStableSwapNGPool(address(sUSDe), address(crvUSD));
        router = new MockCurveRouterNGRouted();
    }

    function _deployStrategyStack() internal {
        vm.startPrank(owner);
        adapter = new CurveAMMAdapter(owner, address(router));
        strategy = new ERC4626MarketYieldStrategy(owner, address(usde), address(sUSDe), address(adapter));
        strategy.setClient(client, true);
        strategy.setSlippageTolerance(100); // 1% default
        vm.stopPrank();
    }

    /// @dev Configure adapter with the exact payload from `AMMRoutes.json` (both directions).
    function _configureRoutes() internal {
        // Forward: USDe -> sUSDe via pool1 (USDe/crvUSD) then pool2 (sUSDe/crvUSD)
        address[11] memory fwdPath;
        fwdPath[0] = address(usde);
        fwdPath[1] = address(pool1);
        fwdPath[2] = address(crvUSD);
        fwdPath[3] = address(pool2);
        fwdPath[4] = address(sUSDe);

        uint256[5][5] memory fwdParams;
        fwdParams[0] = [uint256(0), 1, 1, 10, 2];
        fwdParams[1] = [uint256(1), 0, 1, 10, 2];

        address[5] memory emptyPools;

        // Reverse: sUSDe -> USDe via pool2 then pool1 (hop order flipped)
        address[11] memory revPath;
        revPath[0] = address(sUSDe);
        revPath[1] = address(pool2);
        revPath[2] = address(crvUSD);
        revPath[3] = address(pool1);
        revPath[4] = address(usde);

        uint256[5][5] memory revParams;
        revParams[0] = [uint256(0), 1, 1, 10, 2];
        revParams[1] = [uint256(1), 0, 1, 10, 2];

        vm.startPrank(owner);
        adapter.setRoute(address(usde), address(sUSDe), fwdPath, fwdParams, emptyPools);
        adapter.setRoute(address(sUSDe), address(usde), revPath, revParams, emptyPools);
        vm.stopPrank();
    }

    function _fundPools() internal {
        usde.mint(address(pool1), POOL_LIQUIDITY);
        crvUSD.mint(address(pool1), POOL_LIQUIDITY);
        crvUSD.mint(address(pool2), POOL_LIQUIDITY);
        sUSDe.mintShares(address(pool2), POOL_LIQUIDITY);
    }

    function _fundClientAndApprove() internal {
        usde.mint(client, CLIENT_INITIAL);
        vm.prank(client);
        usde.approve(address(strategy), type(uint256).max);
    }

    // ============ Scenario 1: Happy-path deposit ============

    function testHappyPathDeposit() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(usde), depositAmount, client);

        assertEq(strategy.principalOf(address(usde), client), depositAmount, "principal should equal deposit");
        assertGt(sUSDe.balanceOf(address(strategy)), 0, "strategy should hold sUSDe shares");

        uint256 totalBal = strategy.totalBalanceOf(address(usde), client);
        assertApproxEqAbs(
            totalBal, depositAmount, depositAmount * 100 / 10000, "totalBalanceOf should match within slippage"
        );
    }

    // ============ Scenario 2: Round-trip withdraw ============

    function testRoundTripWithdraw() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(usde), depositAmount, client);

        uint256 clientUsdeBefore = usde.balanceOf(client);

        vm.prank(client);
        strategy.withdraw(address(usde), depositAmount, client);

        assertEq(strategy.principalOf(address(usde), client), 0, "principal should be zero after full withdraw");

        uint256 usdeReceived = usde.balanceOf(client) - clientUsdeBefore;
        assertApproxEqAbs(
            usdeReceived, depositAmount, depositAmount * 100 / 10000, "should receive deposit within slippage"
        );

        // Strategy should hold only dust (rounding) at most
        assertLe(sUSDe.balanceOf(address(strategy)), 1, "strategy vault balance should be dust");
    }

    // ============ Scenario 3: Yield distribution ============

    function testYieldDistribution() public {
        uint256 depositAmount = 1000e18;

        vm.prank(client);
        strategy.deposit(address(usde), depositAmount, client);

        // Appreciate share price by 5%
        sUSDe.advanceYield(500);

        uint256 totalBal = strategy.totalBalanceOf(address(usde), client);
        assertApproxEqAbs(totalBal, 1050e18, 1050e18 * 100 / 10000, "totalBalance should reflect +5% yield");
        assertEq(strategy.principalOf(address(usde), client), depositAmount, "principal unchanged by yield");
    }

    // ============ Scenario 4: Multi-user proportional yield ============

    function testMultiUserProportionalYield() public {
        uint256 deposit1 = 1000e18;
        uint256 deposit2 = 3000e18;

        vm.startPrank(client);
        strategy.deposit(address(usde), deposit1, user1);
        strategy.deposit(address(usde), deposit2, user2);
        vm.stopPrank();

        sUSDe.advanceYield(1000); // +10%

        uint256 tot1 = strategy.totalBalanceOf(address(usde), user1);
        uint256 tot2 = strategy.totalBalanceOf(address(usde), user2);

        // Each user should see ~10% appreciation on their respective principal
        assertApproxEqAbs(tot1, 1100e18, 1100e18 * 100 / 10000, "user1 total balance +10%");
        assertApproxEqAbs(tot2, 3300e18, 3300e18 * 100 / 10000, "user2 total balance +10%");

        // Proportional invariant: tot2 should be ~3x tot1
        assertApproxEqAbs(tot2, tot1 * 3, tot1 * 100 / 10000, "tot2 should be 3x tot1");
    }

    // ============ Scenario 5: Restricted vault regression guard ============

    function testRestrictedVaultEntryPointsAllRevert() public {
        vm.expectRevert("MockRestrictedERC4626Vault: cooldown active");
        sUSDe.deposit(1e18, address(this));

        vm.expectRevert("MockRestrictedERC4626Vault: cooldown active");
        sUSDe.mint(1e18, address(this));

        vm.expectRevert("MockRestrictedERC4626Vault: cooldown active");
        sUSDe.withdraw(1e18, address(this), address(this));

        vm.expectRevert("MockRestrictedERC4626Vault: cooldown active");
        sUSDe.redeem(1e18, address(this), address(this));
    }

    // ============ Scenario 6: Slippage revert on deposit ============

    function testSlippageRevertOnDeposit() public {
        vm.prank(owner);
        strategy.setSlippageTolerance(50); // 0.5%
        pool1.setSlippageBps(100); // 1% price deterioration

        vm.prank(client);
        vm.expectRevert();
        strategy.deposit(address(usde), 1000e18, client);
    }

    // ============ Scenario 7: Slippage revert on withdraw ============

    function testSlippageRevertOnWithdraw() public {
        // Deposit first without slippage
        vm.prank(client);
        strategy.deposit(address(usde), 1000e18, client);

        vm.prank(owner);
        strategy.setSlippageTolerance(50); // 0.5%
        pool2.setSlippageBps(100); // 1% deterioration on reverse path's first hop (sUSDe -> crvUSD)

        vm.prank(client);
        vm.expectRevert();
        strategy.withdraw(address(usde), 1000e18, client);
    }

    // ============ Scenario 8: Bidirectional invariant via strategy ============

    function testBidirectionalInvariantViaStrategy() public {
        // Fresh adapter/strategy with only the forward route configured
        vm.startPrank(owner);
        CurveAMMAdapter freshAdapter = new CurveAMMAdapter(owner, address(router));
        ERC4626MarketYieldStrategy freshStrategy =
            new ERC4626MarketYieldStrategy(owner, address(usde), address(sUSDe), address(freshAdapter));
        freshStrategy.setClient(client, true);
        freshStrategy.setSlippageTolerance(100);

        address[11] memory fwdPath;
        fwdPath[0] = address(usde);
        fwdPath[1] = address(pool1);
        fwdPath[2] = address(crvUSD);
        fwdPath[3] = address(pool2);
        fwdPath[4] = address(sUSDe);

        uint256[5][5] memory fwdParams;
        fwdParams[0] = [uint256(0), 1, 1, 10, 2];
        fwdParams[1] = [uint256(1), 0, 1, 10, 2];

        address[5] memory emptyPools;
        freshAdapter.setRoute(address(usde), address(sUSDe), fwdPath, fwdParams, emptyPools);
        vm.stopPrank();

        vm.prank(client);
        usde.approve(address(freshStrategy), type(uint256).max);

        // Attempt to deposit; should revert with reverse-direction error
        vm.prank(client);
        vm.expectRevert("CurveAMMAdapter: reverse direction not configured");
        freshStrategy.deposit(address(usde), 1000e18, client);

        // Now configure the reverse route
        address[11] memory revPath;
        revPath[0] = address(sUSDe);
        revPath[1] = address(pool2);
        revPath[2] = address(crvUSD);
        revPath[3] = address(pool1);
        revPath[4] = address(usde);

        uint256[5][5] memory revParams;
        revParams[0] = [uint256(0), 1, 1, 10, 2];
        revParams[1] = [uint256(1), 0, 1, 10, 2];

        vm.prank(owner);
        freshAdapter.setRoute(address(sUSDe), address(usde), revPath, revParams, emptyPools);

        // Deposit should now succeed
        vm.prank(client);
        freshStrategy.deposit(address(usde), 1000e18, client);
        assertEq(freshStrategy.principalOf(address(usde), client), 1000e18);
    }

    // ============ Scenario 9: Coin index sanity check ============

    function testCoinIndicesMatchSeedData() public view {
        assertEq(pool1.coins(0), address(usde), "pool1 coin0 should be USDe");
        assertEq(pool1.coins(1), address(crvUSD), "pool1 coin1 should be crvUSD");
        assertEq(pool2.coins(0), address(sUSDe), "pool2 coin0 should be sUSDe");
        assertEq(pool2.coins(1), address(crvUSD), "pool2 coin1 should be crvUSD");
    }

    // ============ Scenario 10: Router walks 3-hop route ============

    // Storage-scoped fixtures for the 3-hop test, used to avoid stack-too-deep.
    MockERC20 internal _alpha;
    MockERC20 internal _beta;
    MockERC20 internal _gamma;
    MockERC20 internal _delta;
    MockCurveStableSwapNGPool internal _poolAB;
    MockCurveStableSwapNGPool internal _poolBG;
    MockCurveStableSwapNGPool internal _poolGD;
    CurveAMMAdapter internal _multiHopAdapter;

    function _deployThreeHopFixtures() internal {
        _alpha = new MockERC20("Alpha", "A", 18);
        _beta = new MockERC20("Beta", "B", 18);
        _gamma = new MockERC20("Gamma", "G", 18);
        _delta = new MockERC20("Delta", "D", 18);

        _poolAB = new MockCurveStableSwapNGPool(address(_alpha), address(_beta));
        _poolBG = new MockCurveStableSwapNGPool(address(_beta), address(_gamma));
        _poolGD = new MockCurveStableSwapNGPool(address(_gamma), address(_delta));

        _alpha.mint(address(_poolAB), POOL_LIQUIDITY);
        _beta.mint(address(_poolAB), POOL_LIQUIDITY);
        _beta.mint(address(_poolBG), POOL_LIQUIDITY);
        _gamma.mint(address(_poolBG), POOL_LIQUIDITY);
        _gamma.mint(address(_poolGD), POOL_LIQUIDITY);
        _delta.mint(address(_poolGD), POOL_LIQUIDITY);
    }

    function _configureThreeHopRoutes() internal {
        address[11] memory path;
        path[0] = address(_alpha);
        path[1] = address(_poolAB);
        path[2] = address(_beta);
        path[3] = address(_poolBG);
        path[4] = address(_gamma);
        path[5] = address(_poolGD);
        path[6] = address(_delta);

        uint256[5][5] memory params;
        params[0] = [uint256(0), 1, 1, 10, 2];
        params[1] = [uint256(0), 1, 1, 10, 2];
        params[2] = [uint256(0), 1, 1, 10, 2];

        address[11] memory revPath;
        revPath[0] = address(_delta);
        revPath[1] = address(_poolGD);
        revPath[2] = address(_gamma);
        revPath[3] = address(_poolBG);
        revPath[4] = address(_beta);
        revPath[5] = address(_poolAB);
        revPath[6] = address(_alpha);

        uint256[5][5] memory revParams;
        revParams[0] = [uint256(1), 0, 1, 10, 2];
        revParams[1] = [uint256(1), 0, 1, 10, 2];
        revParams[2] = [uint256(1), 0, 1, 10, 2];

        address[5] memory emptyPools;

        vm.startPrank(owner);
        _multiHopAdapter = new CurveAMMAdapter(owner, address(router));
        _multiHopAdapter.setRoute(address(_alpha), address(_delta), path, params, emptyPools);
        _multiHopAdapter.setRoute(address(_delta), address(_alpha), revPath, revParams, emptyPools);
        vm.stopPrank();
    }

    function testRouterWalks3HopRoute() public {
        _deployThreeHopFixtures();
        _configureThreeHopRoutes();

        _alpha.mint(address(this), 500e18);
        _alpha.approve(address(_multiHopAdapter), 500e18);

        uint256 deltaBefore = _delta.balanceOf(address(this));
        uint256 amountOut = _multiHopAdapter.swap(address(_alpha), address(_delta), 500e18, 0);
        uint256 deltaAfter = _delta.balanceOf(address(this));

        assertEq(amountOut, 500e18, "3-hop swap at 1:1 should yield input amount");
        assertEq(deltaAfter - deltaBefore, 500e18, "caller should receive delta output");
    }
}
