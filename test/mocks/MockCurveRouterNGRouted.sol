// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/AMMAdapters/ICurveRouterNG.sol";
import "./MockCurveStableSwapNGPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockCurveRouterNGRouted
 * @notice Route-walking mock of the Curve Router NG for integration tests
 * @dev Dispatches each hop to a registered `MockCurveStableSwapNGPool`, chaining the output
 *      of each hop as the input of the next. Only supports `swap_type == 1` and
 *      `pool_type == 10` (plain Stableswap-NG `exchange`). Stores pass-through fields so
 *      integration tests can still assert the adapter forwarded the route payload unchanged.
 */
contract MockCurveRouterNGRouted is ICurveRouterNG {
    using SafeERC20 for IERC20;

    /// @notice Last-seen route array (for pass-through assertions)
    address[11] public lastRoute;

    /// @notice Last-seen swap params matrix
    uint256[5][5] public lastSwapParams;

    /// @notice Last-seen pools array
    address[5] public lastPools;

    /// @notice Last-seen input amount
    uint256 public lastAmount;

    /// @notice Last-seen expected (minimum) output
    uint256 public lastExpected;

    /// @notice Last-seen receiver
    address public lastReceiver;

    /// @notice Last-seen msg.sender for the call
    address public lastCaller;

    /// @inheritdoc ICurveRouterNG
    function exchange(
        address[11] calldata _route,
        uint256[5][5] calldata _swap_params,
        uint256 _amount,
        uint256 _expected,
        address[5] calldata _pools,
        address _receiver
    ) external payable override returns (uint256) {
        // Store pass-through fields for test assertions
        lastRoute = _route;
        lastSwapParams = _swap_params;
        lastPools = _pools;
        lastAmount = _amount;
        lastExpected = _expected;
        lastReceiver = _receiver;
        lastCaller = msg.sender;

        address currentTokenIn = _route[0];
        require(currentTokenIn != address(0), "MockCurveRouterNGRouted: empty route");

        // Pull the initial amount of the first input token from the caller
        IERC20(currentTokenIn).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 dx = _amount;
        (currentTokenIn, dx) = _walkRoute(_route, _swap_params, currentTokenIn, dx);

        require(dx >= _expected, "MockCurveRouterNGRouted: final output below expected");

        // Deliver final amount to the receiver
        IERC20(currentTokenIn).safeTransfer(_receiver, dx);
        return dx;
    }

    /**
     * @dev Walk the route array hop by hop, dispatching each hop to the registered pool.
     *      Extracted into its own function to avoid stack-too-deep in `exchange`.
     */
    function _walkRoute(
        address[11] calldata _route,
        uint256[5][5] calldata _swap_params,
        address startTokenIn,
        uint256 startDx
    ) internal returns (address currentTokenIn, uint256 dx) {
        currentTokenIn = startTokenIn;
        dx = startDx;
        bool anyHopExecuted = false;

        for (uint256 k = 0; k < 5; k++) {
            address pool = _route[2 * k + 1];
            if (pool == address(0)) break;

            address tokenOut = _route[2 * k + 2];
            require(tokenOut != address(0), "MockCurveRouterNGRouted: malformed route");

            require(_swap_params[k][2] == 1, "MockCurveRouterNGRouted: only swap_type=1 supported");
            require(_swap_params[k][3] == 10, "MockCurveRouterNGRouted: only pool_type=10 supported");

            IERC20(currentTokenIn).forceApprove(pool, dx);
            dx = MockCurveStableSwapNGPool(pool)
                .exchange(int128(uint128(_swap_params[k][0])), int128(uint128(_swap_params[k][1])), dx, 0);

            currentTokenIn = tokenOut;
            anyHopExecuted = true;
        }

        require(anyHopExecuted, "MockCurveRouterNGRouted: no hops executed");
    }
}
