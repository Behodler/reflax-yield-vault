// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../../src/AMMAdapters/CurveAMMAdapter.sol";
import "../../src/mocks/MockERC20.sol";
import "../mocks/MockCurveRouterNG.sol";

/**
 * @title CurveAMMAdapterRouteGapTest
 * @notice Audit M-01 class: `setRoute` must only store routes whose Curve Router NG v1.1 executed
 *         prefix actually delivers `tokenOut`.
 * @dev Router NG executes hop k while `path[2k+1] != 0` and delivers `path[2k]` at the first empty pool
 *      slot. The old "last non-zero entry == tokenOut" check accepted `[USDe, pool, crvUSD, 0, ..., sUSDe]`,
 *      which the router executes as a single hop delivering crvUSD. Template: sya-harvester
 *      `test/SYAHarvester.routeGap.t.sol`.
 */
contract CurveAMMAdapterRouteGapTest is Test {
    CurveAMMAdapter adapter;
    MockCurveRouterNG router;

    MockERC20 usde;
    MockERC20 crvusd;
    MockERC20 susde;

    address owner = address(0xA11CE);
    address constant POOL1 = address(0xF55B);
    address constant POOL2 = address(0x5706);

    function setUp() public {
        usde = new MockERC20("USDe", "USDe", 18);
        crvusd = new MockERC20("crvUSD", "crvUSD", 18);
        susde = new MockERC20("sUSDe", "sUSDe", 18);
        router = new MockCurveRouterNG();
        adapter = new CurveAMMAdapter(owner, address(router));
        crvusd.mint(address(router), 1e30);
        susde.mint(address(router), 1e30);
        usde.mint(address(router), 1e30);
    }

    // ============ helpers ============

    function _row(uint256 i, uint256 j) internal pure returns (uint256[5] memory r) {
        r[0] = i;
        r[1] = j;
        r[2] = 1; // swap_type = exchange
        r[3] = 10; // pool_type = Stableswap-NG
        r[4] = 2; // n_coins
    }

    /// @dev Canonical-shaped USDe -> crvUSD -> sUSDe two-hop route
    function _twoHop()
        internal
        view
        returns (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools)
    {
        p[0] = address(usde);
        p[1] = POOL1;
        p[2] = address(crvusd);
        p[3] = POOL2;
        p[4] = address(susde);
        sp[0] = _row(0, 1);
        sp[1] = _row(0, 1);
        pools; // all zero
    }

    /// @dev The exact M-01 shape: one executed hop, then a gap, then a trailing tokenOut
    function _gapPath() internal view returns (address[11] memory p) {
        p[0] = address(usde);
        p[1] = POOL1;
        p[2] = address(crvusd);
        p[10] = address(susde);
    }

    function _oneHopParams() internal pure returns (uint256[5][5] memory sp) {
        sp[0] = _row(0, 1);
    }

    function _set(address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) internal {
        vm.prank(owner);
        adapter.setRoute(address(usde), address(susde), p, sp, pools);
    }

    function _expectSetReverts(bytes memory err, address[11] memory p, uint256[5][5] memory sp, address[5] memory pools)
        internal
    {
        vm.prank(owner);
        vm.expectRevert(err);
        adapter.setRoute(address(usde), address(susde), p, sp, pools);
    }

    // ============ M-01: gap followed by trailing tokenOut ============

    function test_routeGap_gappedRouteCannotBeStored() public {
        address[5] memory pools;
        _expectSetReverts(
            abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteGap.selector, 10), _gapPath(), _oneHopParams(), pools
        );
        (,,, bool configured) = adapter.getRoute(address(usde), address(susde));
        assertFalse(configured, "gapped route must not be stored");
    }

    function test_routeGap_gapAtNextTokenSlotRejected() public {
        // [USDe, P1, crvUSD, 0, sUSDe]: pool slot 3 empty, so path[4] is never reached
        address[11] memory p;
        p[0] = address(usde);
        p[1] = POOL1;
        p[2] = address(crvusd);
        p[4] = address(susde);
        address[5] memory pools;
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteGap.selector, 4), p, _oneHopParams(), pools);
    }

    function test_routeGap_trailingPoolAfterGapRejected() public {
        // A stray pool after the executed prefix is also a gap
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        p[7] = address(0xBEEF);
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteGap.selector, 7), p, sp, pools);
    }

    function test_routeGap_gappedRouteDoesNotOverwriteValidRoute() public {
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        _set(p, sp, pools);

        address[5] memory noPools;
        _expectSetReverts(
            abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteGap.selector, 10), _gapPath(), _oneHopParams(), noPools
        );

        (address[11] memory stored,,, bool configured) = adapter.getRoute(address(usde), address(susde));
        assertTrue(configured);
        assertEq(stored[2], address(crvusd));
        assertEq(stored[4], address(susde));
        assertEq(stored[10], address(0));
    }

    function test_routeGap_mockDeliversIntermediateForGappedPath() public {
        // What the gapped route would have done: the faithful mock (like Router NG) pays crvUSD, not sUSDe
        address receiver = makeAddr("receiver");
        usde.mint(address(this), 100e18);
        usde.approve(address(router), 100e18);
        address[5] memory pools;
        router.exchange(_gapPath(), _oneHopParams(), 100e18, 0, pools, receiver);
        assertEq(crvusd.balanceOf(receiver), 100e18, "intermediate delivered");
        assertEq(susde.balanceOf(receiver), 0, "trailing tokenOut not delivered");
    }

    // ============ zero intermediate / zero delivered token ============

    function test_routeGap_zeroIntermediateRejected() public {
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        p[2] = address(0);
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteToken.selector, 2), p, sp, pools);
    }

    function test_routeGap_zeroDeliveredTokenRejected() public {
        address[11] memory p;
        p[0] = address(usde);
        p[1] = POOL1;
        address[5] memory pools;
        _expectSetReverts(
            abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteEnd.selector, address(susde), address(0)),
            p,
            _oneHopParams(),
            pools
        );
    }

    function test_routeGap_mockRevertsOnZeroIntermediate() public {
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        p[2] = address(0);
        vm.expectRevert("MockCurveRouterNG: zero token in executed hop");
        router.exchange(p, sp, 1e18, 0, pools, address(this));
    }

    // ============ swap_type on executed hops ============

    function test_routeGap_swapTypeZeroOnFirstHopRejected() public {
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        sp[0][2] = 0;
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteSwapParams.selector, 0), p, sp, pools);
    }

    function test_routeGap_swapTypeZeroOnLaterHopRejected() public {
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        sp[1][2] = 0;
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteSwapParams.selector, 1), p, sp, pools);
    }

    function test_routeGap_swapTypeNineRejected() public {
        // Router NG v1.1 rejects swap_type 9 (ERC4626 redeem) with "Bad swap type"
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        sp[1][2] = 9;
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteSwapParams.selector, 1), p, sp, pools);
    }

    function test_routeGap_mockRevertsOnSwapTypeZero() public {
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        sp[0][2] = 0;
        vm.expectRevert("MockCurveRouterNG: Bad swap type");
        router.exchange(p, sp, 1e18, 0, pools, address(this));
    }

    // ============ unexecuted rows and pools ============

    function test_routeGap_nonZeroUnexecutedSwapParamsRowRejected() public {
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        sp[2] = _row(0, 1);
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteSwapParams.selector, 2), p, sp, pools);
    }

    function test_routeGap_nonZeroFieldInUnexecutedRowRejected() public {
        // Any field, not just swap_type, of a row the router never reads must be zero
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        sp[4][4] = 2;
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteSwapParams.selector, 4), p, sp, pools);
    }

    function test_routeGap_nonZeroUnexecutedPoolRejected() public {
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        pools[2] = address(0xCAFE);
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRoutePools.selector, 2), p, sp, pools);
    }

    function test_routeGap_executedHopPoolAllowed() public {
        // Base pools on executed hops (meta-swaps) are not constrained
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        pools[0] = address(0xCAFE);
        pools[1] = address(0xBABE);
        _set(p, sp, pools);
        (,, address[5] memory stored, bool configured) = adapter.getRoute(address(usde), address(susde));
        assertTrue(configured);
        assertEq(stored[0], address(0xCAFE));
        assertEq(stored[1], address(0xBABE));
    }

    // ============ k = 0 ============

    function test_routeGap_zeroHopRouteRejected() public {
        // path[1] == 0: no hop executes, so the router would deliver tokenIn
        address[11] memory p;
        p[0] = address(usde);
        p[2] = address(susde);
        uint256[5][5] memory sp;
        address[5] memory pools;
        _expectSetReverts(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteEmpty.selector), p, sp, pools);
    }

    function test_routeGap_zeroHopSelfRouteRejected() public {
        // tokenIn == tokenOut with no hops would pass the end check on its own; the k >= 1 guard stops it
        address[11] memory p;
        p[0] = address(usde);
        uint256[5][5] memory sp;
        address[5] memory pools;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CurveAMMAdapter.InvalidRouteEmpty.selector));
        adapter.setRoute(address(usde), address(usde), p, sp, pools);
    }

    // ============ accepted routes ============

    function test_routeGap_fiveHopRouteAccepted() public {
        // k == 5 boundary: path[10] is the delivered token and there is no slot after it
        address[11] memory p;
        uint256[5][5] memory sp;
        address[5] memory pools;
        p[0] = address(usde);
        for (uint256 h = 0; h < 5; h++) {
            p[2 * h + 1] = address(uint160(0x1000 + h));
            p[2 * h + 2] = h == 4 ? address(susde) : address(crvusd);
            sp[h] = _row(0, 1);
        }
        _set(p, sp, pools);
        (address[11] memory stored,,, bool configured) = adapter.getRoute(address(usde), address(susde));
        assertTrue(configured);
        assertEq(stored[10], address(susde));
    }

    function test_routeGap_contiguousRouteSwapsToTokenOut() public {
        // End to end through the faithful mock: a stored route delivers tokenOut
        (address[11] memory p, uint256[5][5] memory sp, address[5] memory pools) = _twoHop();
        _set(p, sp, pools);
        address[11] memory r;
        r[0] = address(susde);
        r[1] = POOL2;
        r[2] = address(crvusd);
        r[3] = POOL1;
        r[4] = address(usde);
        uint256[5][5] memory rsp;
        rsp[0] = _row(1, 0);
        rsp[1] = _row(1, 0);
        vm.prank(owner);
        adapter.setRoute(address(susde), address(usde), r, rsp, pools);

        address strategy = makeAddr("strategy");
        usde.mint(strategy, 10e18);
        vm.startPrank(strategy);
        usde.approve(address(adapter), 10e18);
        uint256 out = adapter.swap(address(usde), address(susde), 10e18, 0);
        vm.stopPrank();
        assertEq(out, 10e18);
        assertEq(susde.balanceOf(strategy), 10e18, "tokenOut delivered");
        assertEq(crvusd.balanceOf(strategy), 0, "no intermediate delivered");
    }

    // ============ AMMRoutes.json regression ============

    struct JsonRoute {
        address tokenIn;
        address tokenOut;
        address[11] path;
        uint256[5][5] swapParams;
        address[5] pools;
    }

    function _parseRoute(string memory json, string memory key, string memory inName, string memory outName)
        internal
        view
        returns (JsonRoute memory r)
    {
        string memory base = string.concat(".Curve.RouterNG.routes.", key);
        r.tokenIn = vm.parseJsonAddress(json, string.concat(base, ".", inName));
        r.tokenOut = vm.parseJsonAddress(json, string.concat(base, ".", outName));
        address[] memory routeArr = vm.parseJsonAddressArray(json, string.concat(base, ".route"));
        address[] memory poolsArr = vm.parseJsonAddressArray(json, string.concat(base, ".pools"));
        assertEq(routeArr.length, 11, "route length");
        assertEq(poolsArr.length, 5, "pools length");
        for (uint256 i = 0; i < 11; i++) {
            r.path[i] = routeArr[i];
        }
        for (uint256 h = 0; h < 5; h++) {
            r.pools[h] = poolsArr[h];
            uint256[] memory row =
                vm.parseJsonUintArray(json, string.concat(base, ".swapParams[", vm.toString(h), "]"));
            assertEq(row.length, 5, "swapParams row length");
            for (uint256 f = 0; f < 5; f++) {
                r.swapParams[h][f] = row[f];
            }
        }
    }

    function _assertStored(CurveAMMAdapter a, JsonRoute memory r) internal view {
        (address[11] memory storedP, uint256[5][5] memory storedSp, address[5] memory storedPools, bool configured) =
            a.getRoute(r.tokenIn, r.tokenOut);
        assertTrue(configured, "canonical route configured");
        for (uint256 i = 0; i < 11; i++) {
            assertEq(storedP[i], r.path[i]);
        }
        for (uint256 h = 0; h < 5; h++) {
            assertEq(storedPools[h], r.pools[h]);
            for (uint256 f = 0; f < 5; f++) {
                assertEq(storedSp[h][f], r.swapParams[h][f]);
            }
        }
    }

    function _setRouteFromJson(CurveAMMAdapter a, string memory json, string memory key, string memory inName, string memory outName)
        internal
        returns (address tokenIn, address tokenOut)
    {
        JsonRoute memory r = _parseRoute(json, key, inName, outName);
        vm.prank(owner);
        a.setRoute(r.tokenIn, r.tokenOut, r.path, r.swapParams, r.pools);
        _assertStored(a, r);
        return (r.tokenIn, r.tokenOut);
    }

    function test_routeGap_canonicalAMMRoutesAccepted() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/AMMRoutes.json"));
        address routerNG = vm.parseJsonAddress(json, ".Curve.RouterNG.router");
        assertEq(routerNG, 0x16C6521Dff6baB339122a0FE25a9116693265353, "Router NG v1.1");

        CurveAMMAdapter a = new CurveAMMAdapter(owner, routerNG);
        (address usdeAddr, address susdeAddr) = _setRouteFromJson(a, json, "USDe-sUSDe", "USDe", "sUSDe");
        (address susdeAddr2, address usdeAddr2) = _setRouteFromJson(a, json, "sUSDe-USDe", "sUSDe", "USDe");

        assertEq(usdeAddr, 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
        assertEq(susdeAddr, 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
        assertEq(usdeAddr, usdeAddr2);
        assertEq(susdeAddr, susdeAddr2);
        assertTrue(a.isPairFullyConfigured(usdeAddr, susdeAddr), "both canonical directions stored");
    }
}
