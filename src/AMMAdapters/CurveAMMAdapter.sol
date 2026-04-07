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
     * @dev Validates `path[0] == tokenIn` and that the last non-zero entry equals `tokenOut`.
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

        // Find the last non-zero entry in path and confirm it equals tokenOut
        address lastToken;
        for (uint256 i = 0; i < 11; i++) {
            if (path[i] != address(0)) {
                lastToken = path[i];
            }
        }
        require(lastToken == tokenOut, "CurveAMMAdapter: path must end at tokenOut");

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
