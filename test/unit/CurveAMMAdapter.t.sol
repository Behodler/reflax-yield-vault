// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/AMMAdapters/CurveAMMAdapter.sol";
import "../../src/AMMAdapters/ICurveRouterNG.sol";
import "../../src/mocks/MockERC20.sol";
import "../mocks/MockCurveRouterNG.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CurveAMMAdapterTest
 * @notice Unit tests for `CurveAMMAdapter` route management, access control, swap execution,
 *         slippage forwarding, and the bidirectional-configuration invariant.
 */
contract CurveAMMAdapterTest is Test {
    CurveAMMAdapter adapter;
    MockCurveRouterNG router;

    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenMid; // used for multi-hop paths

    address owner = address(0xA11CE);
    address nonOwner = address(0xB0B);
    address strategy = address(0xDEAD);

    uint256 constant INITIAL_SUPPLY = 1_000_000e18;

    event RouteSet(address indexed tokenIn, address indexed tokenOut);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenMid = new MockERC20("Mid Token", "MID", 18);

        router = new MockCurveRouterNG();

        vm.prank(owner);
        adapter = new CurveAMMAdapter(owner, address(router));

        // Fund router with reserves so it can satisfy swaps in either direction
        tokenA.mint(address(router), INITIAL_SUPPLY);
        tokenB.mint(address(router), INITIAL_SUPPLY);
        tokenMid.mint(address(router), INITIAL_SUPPLY);

        // Fund the strategy caller with tokens and have it approve the adapter
        tokenA.mint(strategy, INITIAL_SUPPLY);
        tokenB.mint(strategy, INITIAL_SUPPLY);

        vm.startPrank(strategy);
        tokenA.approve(address(adapter), type(uint256).max);
        tokenB.approve(address(adapter), type(uint256).max);
        vm.stopPrank();
    }

    // ============ setRoute tests ============

    function _makeSimplePath(address tokenIn, address pool, address tokenOut) internal pure returns (address[11] memory path) {
        path[0] = tokenIn;
        path[1] = pool;
        path[2] = tokenOut;
    }

    function _makeSimpleSwapParams(uint256 i, uint256 j) internal pure returns (uint256[5][5] memory params) {
        params[0][0] = i;
        params[0][1] = j;
        params[0][2] = 1; // swap_type = exchange
        params[0][3] = 10; // pool_type = Stableswap-NG
        params[0][4] = 2; // n_coins
    }

    function _emptyPools() internal pure returns (address[5] memory pools) {}

    function _configurePair(address a, address b) internal {
        address poolAB = address(0xAABB);
        address poolBA = address(0xBBAA);
        vm.startPrank(owner);
        adapter.setRoute(a, b, _makeSimplePath(a, poolAB, b), _makeSimpleSwapParams(0, 1), _emptyPools());
        adapter.setRoute(b, a, _makeSimplePath(b, poolBA, a), _makeSimpleSwapParams(1, 0), _emptyPools());
        vm.stopPrank();
    }

    function testSetRouteSucceedsFromOwnerAndEmitsEvent() public {
        address poolAB = address(0xAABB);
        address[11] memory path = _makeSimplePath(address(tokenA), poolAB, address(tokenB));
        uint256[5][5] memory params = _makeSimpleSwapParams(0, 1);
        address[5] memory pools = _emptyPools();

        vm.expectEmit(true, true, false, false);
        emit RouteSet(address(tokenA), address(tokenB));

        vm.prank(owner);
        adapter.setRoute(address(tokenA), address(tokenB), path, params, pools);

        (address[11] memory storedPath, uint256[5][5] memory storedParams,, bool configured) =
            adapter.getRoute(address(tokenA), address(tokenB));
        assertTrue(configured, "route should be configured");
        assertEq(storedPath[0], address(tokenA));
        assertEq(storedPath[1], poolAB);
        assertEq(storedPath[2], address(tokenB));
        assertEq(storedParams[0][0], 0);
        assertEq(storedParams[0][1], 1);
        assertEq(storedParams[0][3], 10);
    }

    function testSetRouteRevertsForNonOwner() public {
        address[11] memory path = _makeSimplePath(address(tokenA), address(0xAABB), address(tokenB));
        uint256[5][5] memory params = _makeSimpleSwapParams(0, 1);
        address[5] memory pools = _emptyPools();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        adapter.setRoute(address(tokenA), address(tokenB), path, params, pools);
    }

    function testSetRouteRevertsWhenPathZeroMismatchesTokenIn() public {
        address[11] memory path;
        path[0] = address(tokenB); // wrong
        path[1] = address(0xAABB);
        path[2] = address(tokenB);
        uint256[5][5] memory params = _makeSimpleSwapParams(0, 1);

        vm.expectRevert("CurveAMMAdapter: path[0] must equal tokenIn");
        vm.prank(owner);
        adapter.setRoute(address(tokenA), address(tokenB), path, params, _emptyPools());
    }

    function testSetRouteRevertsWhenLastNonZeroDoesNotMatchTokenOut() public {
        address[11] memory path;
        path[0] = address(tokenA);
        path[1] = address(0xAABB);
        path[2] = address(tokenMid); // wrong end
        uint256[5][5] memory params = _makeSimpleSwapParams(0, 1);

        vm.expectRevert("CurveAMMAdapter: path must end at tokenOut");
        vm.prank(owner);
        adapter.setRoute(address(tokenA), address(tokenB), path, params, _emptyPools());
    }

    function testSetRouteRevertsOnZeroTokenIn() public {
        address[11] memory path = _makeSimplePath(address(0), address(0xAABB), address(tokenB));
        uint256[5][5] memory params = _makeSimpleSwapParams(0, 1);

        vm.expectRevert("CurveAMMAdapter: tokenIn cannot be zero");
        vm.prank(owner);
        adapter.setRoute(address(0), address(tokenB), path, params, _emptyPools());
    }

    function testSetRouteRevertsOnZeroTokenOut() public {
        address[11] memory path = _makeSimplePath(address(tokenA), address(0xAABB), address(0));
        uint256[5][5] memory params = _makeSimpleSwapParams(0, 1);

        vm.expectRevert("CurveAMMAdapter: tokenOut cannot be zero");
        vm.prank(owner);
        adapter.setRoute(address(tokenA), address(0), path, params, _emptyPools());
    }

    // ============ getRoute tests ============

    function testGetRouteReturnsConfiguredFalseForUnsetPair() public view {
        (,,, bool configured) = adapter.getRoute(address(tokenA), address(tokenB));
        assertFalse(configured, "unset pair should not be configured");
    }

    function testGetRouteReturnsStoredValues() public {
        address poolAB = address(0xAABB);
        vm.prank(owner);
        adapter.setRoute(
            address(tokenA),
            address(tokenB),
            _makeSimplePath(address(tokenA), poolAB, address(tokenB)),
            _makeSimpleSwapParams(0, 1),
            _emptyPools()
        );

        (address[11] memory path,, address[5] memory pools, bool configured) =
            adapter.getRoute(address(tokenA), address(tokenB));
        assertTrue(configured);
        assertEq(path[1], poolAB);
        assertEq(pools[0], address(0));
    }

    // ============ isPairFullyConfigured tests ============

    function testIsPairFullyConfiguredFalseWhenNeitherSet() public view {
        assertFalse(adapter.isPairFullyConfigured(address(tokenA), address(tokenB)));
    }

    function testIsPairFullyConfiguredFalseWhenOnlyForwardSet() public {
        vm.prank(owner);
        adapter.setRoute(
            address(tokenA),
            address(tokenB),
            _makeSimplePath(address(tokenA), address(0xAABB), address(tokenB)),
            _makeSimpleSwapParams(0, 1),
            _emptyPools()
        );
        assertFalse(adapter.isPairFullyConfigured(address(tokenA), address(tokenB)));
    }

    function testIsPairFullyConfiguredFalseWhenOnlyReverseSet() public {
        vm.prank(owner);
        adapter.setRoute(
            address(tokenB),
            address(tokenA),
            _makeSimplePath(address(tokenB), address(0xBBAA), address(tokenA)),
            _makeSimpleSwapParams(1, 0),
            _emptyPools()
        );
        assertFalse(adapter.isPairFullyConfigured(address(tokenA), address(tokenB)));
    }

    function testIsPairFullyConfiguredTrueAfterBothDirectionsSet() public {
        _configurePair(address(tokenA), address(tokenB));
        assertTrue(adapter.isPairFullyConfigured(address(tokenA), address(tokenB)));
        assertTrue(adapter.isPairFullyConfigured(address(tokenB), address(tokenA)));
    }

    // ============ swap tests ============

    function testSwapRevertsWhenNeitherDirectionConfigured() public {
        vm.prank(strategy);
        vm.expectRevert("CurveAMMAdapter: route not configured");
        adapter.swap(address(tokenA), address(tokenB), 100e18, 0);
    }

    function testSwapForwardRevertsWhenOnlyForwardConfigured() public {
        vm.prank(owner);
        adapter.setRoute(
            address(tokenA),
            address(tokenB),
            _makeSimplePath(address(tokenA), address(0xAABB), address(tokenB)),
            _makeSimpleSwapParams(0, 1),
            _emptyPools()
        );
        vm.prank(strategy);
        vm.expectRevert("CurveAMMAdapter: reverse direction not configured");
        adapter.swap(address(tokenA), address(tokenB), 100e18, 0);
    }

    function testSwapReverseRevertsWhenOnlyForwardConfigured() public {
        vm.prank(owner);
        adapter.setRoute(
            address(tokenA),
            address(tokenB),
            _makeSimplePath(address(tokenA), address(0xAABB), address(tokenB)),
            _makeSimpleSwapParams(0, 1),
            _emptyPools()
        );
        vm.prank(strategy);
        // swap(B -> A) should also revert because route[B][A] is unset.
        // Error is "route not configured" because the forward lookup is the first check.
        vm.expectRevert("CurveAMMAdapter: route not configured");
        adapter.swap(address(tokenB), address(tokenA), 100e18, 0);
    }

    function testSwapBothDirectionsSucceedAfterFullConfiguration() public {
        _configurePair(address(tokenA), address(tokenB));

        uint256 balBefore = tokenB.balanceOf(strategy);
        vm.prank(strategy);
        uint256 outAB = adapter.swap(address(tokenA), address(tokenB), 100e18, 0);
        assertEq(outAB, 100e18, "A->B should swap at default 1:1");
        assertEq(tokenB.balanceOf(strategy) - balBefore, 100e18);

        balBefore = tokenA.balanceOf(strategy);
        vm.prank(strategy);
        uint256 outBA = adapter.swap(address(tokenB), address(tokenA), 50e18, 0);
        assertEq(outBA, 50e18, "B->A should swap at default 1:1");
        assertEq(tokenA.balanceOf(strategy) - balBefore, 50e18);
    }

    function testSwapRevertsOnZeroAmountIn() public {
        _configurePair(address(tokenA), address(tokenB));
        vm.prank(strategy);
        vm.expectRevert("CurveAMMAdapter: amountIn must be > 0");
        adapter.swap(address(tokenA), address(tokenB), 0, 0);
    }

    function testSwapPullsAmountInFromCaller() public {
        _configurePair(address(tokenA), address(tokenB));
        uint256 balBefore = tokenA.balanceOf(strategy);

        vm.prank(strategy);
        adapter.swap(address(tokenA), address(tokenB), 100e18, 0);

        assertEq(balBefore - tokenA.balanceOf(strategy), 100e18);
    }

    function testSwapReturnsRouterAmountAndCreditsCaller() public {
        _configurePair(address(tokenA), address(tokenB));
        router.setExchangeRate(address(tokenA), address(tokenB), 2e18); // 1 A -> 2 B

        vm.prank(strategy);
        uint256 amountOut = adapter.swap(address(tokenA), address(tokenB), 10e18, 0);
        assertEq(amountOut, 20e18);
        assertEq(tokenB.balanceOf(strategy), INITIAL_SUPPLY + 20e18);
    }

    function testSwapForwardsMinAmountOutToRouter() public {
        _configurePair(address(tokenA), address(tokenB));
        router.setExchangeRate(address(tokenA), address(tokenB), 9e17); // 10% slippage

        vm.prank(strategy);
        vm.expectRevert("MockCurveRouterNG: insufficient output amount");
        adapter.swap(address(tokenA), address(tokenB), 100e18, 100e18);
    }

    function testSwapPassesRoutePayloadThroughToRouter() public {
        address poolAB = address(0xAABB);
        address poolBA = address(0xBBAA);
        // Configure both directions with distinct payloads
        uint256[5][5] memory paramsAB = _makeSimpleSwapParams(0, 1);
        paramsAB[0][4] = 7; // distinctive n_coins marker
        uint256[5][5] memory paramsBA = _makeSimpleSwapParams(1, 0);
        paramsBA[0][4] = 9; // distinctive marker

        address[5] memory poolsAB;
        poolsAB[0] = address(0xCAFE);
        address[5] memory poolsBA;
        poolsBA[0] = address(0xBABE);

        vm.startPrank(owner);
        adapter.setRoute(
            address(tokenA),
            address(tokenB),
            _makeSimplePath(address(tokenA), poolAB, address(tokenB)),
            paramsAB,
            poolsAB
        );
        adapter.setRoute(
            address(tokenB),
            address(tokenA),
            _makeSimplePath(address(tokenB), poolBA, address(tokenA)),
            paramsBA,
            poolsBA
        );
        vm.stopPrank();

        vm.prank(strategy);
        adapter.swap(address(tokenA), address(tokenB), 50e18, 0);

        // Assert pass-through: router saw the A->B payload
        assertEq(router.lastRoute(0), address(tokenA));
        assertEq(router.lastRoute(1), poolAB);
        assertEq(router.lastRoute(2), address(tokenB));
        assertEq(router.lastAmount(), 50e18);
        assertEq(router.lastReceiver(), strategy);
        assertEq(router.lastCaller(), address(adapter));
        assertEq(router.lastPools(0), address(0xCAFE));
        assertEq(router.lastSwapParams(0, 4), 7);

        // Now swap B -> A and assert the router sees the B->A payload (distinct fields)
        vm.prank(strategy);
        adapter.swap(address(tokenB), address(tokenA), 25e18, 0);

        assertEq(router.lastRoute(0), address(tokenB));
        assertEq(router.lastRoute(1), poolBA);
        assertEq(router.lastRoute(2), address(tokenA));
        assertEq(router.lastAmount(), 25e18);
        assertEq(router.lastReceiver(), strategy);
        assertEq(router.lastPools(0), address(0xBABE));
        assertEq(router.lastSwapParams(0, 4), 9);
    }

    function testSwapEmitsSwappedEvent() public {
        _configurePair(address(tokenA), address(tokenB));
        vm.expectEmit(true, true, false, true);
        emit Swapped(address(tokenA), address(tokenB), 100e18, 100e18);

        vm.prank(strategy);
        adapter.swap(address(tokenA), address(tokenB), 100e18, 0);
    }

    function testSwapMultiHopPathPassThrough() public {
        // Configure a 3-hop path in the forward direction (unused by router for pricing)
        address[11] memory path;
        path[0] = address(tokenA);
        path[1] = address(0xA001);
        path[2] = address(tokenMid);
        path[3] = address(0xA002);
        path[4] = address(tokenMid); // reused intermediate
        path[5] = address(0xA003);
        path[6] = address(tokenB);

        uint256[5][5] memory params;
        for (uint256 h = 0; h < 3; h++) {
            params[h][0] = 0;
            params[h][1] = 1;
            params[h][2] = 1;
            params[h][3] = 10;
            params[h][4] = 2;
        }

        address[5] memory pools;

        vm.prank(owner);
        adapter.setRoute(address(tokenA), address(tokenB), path, params, pools);
        // Configure reverse to satisfy invariant (simple 1-hop reverse)
        vm.prank(owner);
        adapter.setRoute(
            address(tokenB),
            address(tokenA),
            _makeSimplePath(address(tokenB), address(0xBBAA), address(tokenA)),
            _makeSimpleSwapParams(1, 0),
            _emptyPools()
        );

        vm.prank(strategy);
        uint256 amountOut = adapter.swap(address(tokenA), address(tokenB), 10e18, 0);
        assertEq(amountOut, 10e18);

        // Assert the 3-hop path reached the router unchanged
        assertEq(router.lastRoute(0), address(tokenA));
        assertEq(router.lastRoute(1), address(0xA001));
        assertEq(router.lastRoute(2), address(tokenMid));
        assertEq(router.lastRoute(3), address(0xA002));
        assertEq(router.lastRoute(4), address(tokenMid));
        assertEq(router.lastRoute(5), address(0xA003));
        assertEq(router.lastRoute(6), address(tokenB));
    }
}
