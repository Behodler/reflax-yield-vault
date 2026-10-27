// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IAMMAdapter.sol";
import "./ICurveRouterNG.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CurveAMMAdapter
 * @notice IAMMAdapter implementation that executes swaps through the Curve Router NG
 * @dev Stores one pre-computed route per ordered (tokenIn, tokenOut) pair. Routes are admin-set
 *      (onlyOwner) because Curve's route encoding is non-trivial and must be verified against
 *      pool coin indices off-chain. The adapter enforces a bidirectional-configuration invariant:
 *      a swap in either direction reverts until BOTH directions of the pair are configured.
 *      This prevents deploying a half-configured adapter into a strategy that needs round-trip
 *      swaps (which every `ERC4626MarketYieldStrategy` does).
 *
 *      Route semantics follow Curve Router NG v1.1: it executes hop k while `path[2k+1] != 0`,
 *      stops at the first empty pool slot and delivers `path[2k]`, ignoring anything after it.
 *      `setRoute` therefore enforces contiguity: a stored route can only be one whose executed
 *      prefix actually delivers `tokenOut` (audit M-01 class fix, ported from SYAHarvester).
 */
contract CurveAMMAdapter is IAMMAdapter, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Pre-computed route payload for a single (tokenIn, tokenOut) direction
    struct Route {
        address[11] path; // Interleaved token/pool addresses for Curve Router NG
        uint256[5][5] swapParams; // Per-hop [i, j, swap_type, pool_type, n_coins]
        address[5] pools; // Optional base pools for meta-swaps
        bool configured; // Distinguishes "unset" from "all zeros"
    }

    /// @notice Curve Router NG used for all swaps
    ICurveRouterNG public immutable router;

    /// @dev tokenIn => tokenOut => Route
    mapping(address => mapping(address => Route)) private routes;

    /// @notice Emitted when an admin configures a route for a (tokenIn, tokenOut) pair
    event RouteSet(address indexed tokenIn, address indexed tokenOut);

    /// @notice Emitted when a swap successfully executes
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    /// @notice The route executes no hop (`path[1] == 0`), so it would swap nothing
    error InvalidRouteEmpty();

    /// @notice The executed prefix delivers `delivered`, not the configured `tokenOut` (`expected`)
    error InvalidRouteEnd(address expected, address delivered);

    /// @notice `path[index]` is non-zero but lies after the executed prefix, so the router never reaches it
    error InvalidRouteGap(uint256 index);

    /// @notice The intermediate token `path[index]` of an executed hop is zero
    error InvalidRouteToken(uint256 index);

    /// @notice `swapParams[hop]` is invalid: an executed hop with swap_type 0 or 9, or a non-zero unexecuted row
    error InvalidRouteSwapParams(uint256 hop);

    /// @notice `pools[hop]` is non-zero for a hop the router never executes
    error InvalidRoutePools(uint256 hop);

    /**
     * @notice Initialize the CurveAMMAdapter
     * @param _owner Initial owner (typically a multisig in production)
     * @param _router Curve Router NG address
     */
    constructor(address _owner, address _router) Ownable(_owner) {
        require(_router != address(0), "CurveAMMAdapter: router cannot be zero");
        router = ICurveRouterNG(_router);
    }

    /**
     * @notice Admin-only: configure the route for a (tokenIn, tokenOut) direction
     * @param tokenIn The token being sold in the configured swap direction
     * @param tokenOut The token being bought in the configured swap direction
     * @param path 11-slot `_route` array to pass to Curve Router NG
     * @param swapParams 5x5 `_swap_params` matrix for the router
     * @param pools 5-slot `_pools` array (base pools for meta-swaps, else zero)
     * @dev Curve Router NG v1.1 executes hop k while `path[2k+1] != 0` and delivers `path[2k]` at the
     *      first empty pool slot, ignoring every later entry. With k the number of executed hops, checks
     *      in this order:
     *      - `tokenIn != 0`, `tokenOut != 0`, `path[0] == tokenIn` (require-strings, unchanged);
     *      - k >= 1, i.e. `path[1] != 0` (`InvalidRouteEmpty`): a zero-hop route would swap nothing;
     *      - no non-zero entry follows the executed prefix, i.e. `path[2k+1..10]` are zero (`InvalidRouteGap`);
     *      - every executed intermediate token `path[2i]`, `0 < i < k`, is non-zero (`InvalidRouteToken`);
     *      - the delivered token `path[2k]` equals `tokenOut` (`InvalidRouteEnd`);
     *      - per hop h in order 0..4: an executed row (h < k) has swap_type `swapParams[h][2]` not 0 and not 9
     *        (Router NG v1.1 rejects both), and an unexecuted row (h >= k) is all zero
     *        (`InvalidRouteSwapParams`) with `pools[h] == 0` (`InvalidRoutePools`). Pools of executed hops
     *        are not constrained (they are base pools for meta-swaps).
     */
    function setRoute(
        address tokenIn,
        address tokenOut,
        address[11] calldata path,
        uint256[5][5] calldata swapParams,
        address[5] calldata pools
    ) external onlyOwner {
        require(tokenIn != address(0), "CurveAMMAdapter: tokenIn cannot be zero");
        require(tokenOut != address(0), "CurveAMMAdapter: tokenOut cannot be zero");
        require(path[0] == tokenIn, "CurveAMMAdapter: path[0] must equal tokenIn");

        // Router NG executes hop k while path[2k+1] != 0 and delivers path[2k] at the first empty pool slot.
        uint256 k;
        while (k < 5 && path[2 * k + 1] != address(0)) k++;
        // A zero-hop route is a no-op that would hand tokenIn straight back; never store one.
        if (k == 0) revert InvalidRouteEmpty();
        // Nothing may follow the executed prefix: a trailing entry is never executed (empty when k == 5).
        for (uint256 i = 2 * k + 1; i < 11; i++) {
            if (path[i] != address(0)) revert InvalidRouteGap(i);
        }
        // Every executed intermediate token must exist: hop i-1 outputs path[2i].
        for (uint256 i = 1; i < k; i++) {
            if (path[2 * i] == address(0)) revert InvalidRouteToken(2 * i);
        }
        address delivered = path[2 * k];
        if (delivered != tokenOut) revert InvalidRouteEnd(tokenOut, delivered);
        // Swap params and pools must match the executed prefix: executed rows dispatch on a swap_type the
        // router accepts (not 0, not 9), and rows and pools the router never reads are zero.
        for (uint256 h = 0; h < 5; h++) {
            if (h < k) {
                uint256 swapType = swapParams[h][2];
                if (swapType == 0 || swapType == 9) revert InvalidRouteSwapParams(h);
            } else {
                for (uint256 f = 0; f < 5; f++) {
                    if (swapParams[h][f] != 0) revert InvalidRouteSwapParams(h);
                }
                if (pools[h] != address(0)) revert InvalidRoutePools(h);
            }
        }

        Route storage r = routes[tokenIn][tokenOut];
        r.path = path;
        r.swapParams = swapParams;
        r.pools = pools;
        r.configured = true;

        emit RouteSet(tokenIn, tokenOut);
    }

    /**
     * @notice View a configured route (useful for off-chain verification)
     * @param tokenIn The swap input token
     * @param tokenOut The swap output token
     * @return path The stored 11-slot route array
     * @return swapParams The stored 5x5 swap params matrix
     * @return pools The stored 5-slot base pools array
     * @return configured True if this direction has been configured
     */
    function getRoute(address tokenIn, address tokenOut)
        external
        view
        returns (address[11] memory path, uint256[5][5] memory swapParams, address[5] memory pools, bool configured)
    {
        Route storage r = routes[tokenIn][tokenOut];
        return (r.path, r.swapParams, r.pools, r.configured);
    }

    /**
     * @notice Returns true only if BOTH directions of the pair are configured
     * @param tokenA First token of the pair
     * @param tokenB Second token of the pair
     * @return True iff `routes[tokenA][tokenB].configured && routes[tokenB][tokenA].configured`
     */
    function isPairFullyConfigured(address tokenA, address tokenB) public view returns (bool) {
        return routes[tokenA][tokenB].configured && routes[tokenB][tokenA].configured;
    }

    /// @inheritdoc IAMMAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        Route storage r = routes[tokenIn][tokenOut];
        require(r.configured, "CurveAMMAdapter: route not configured");
        // Bidirectional invariant: both directions must be configured before either can be used
        require(routes[tokenOut][tokenIn].configured, "CurveAMMAdapter: reverse direction not configured");
        require(amountIn > 0, "CurveAMMAdapter: amountIn must be > 0");

        // Pull tokens from caller (strategy)
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve router for exactly amountIn (reset-then-set pattern for safety)
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // Execute swap; router sends output directly back to caller (receiver = msg.sender)
        amountOut = router.exchange(r.path, r.swapParams, amountIn, minAmountOut, r.pools, msg.sender);

        emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
    }
}
