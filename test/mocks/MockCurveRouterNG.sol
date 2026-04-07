// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/AMMAdapters/ICurveRouterNG.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockCurveRouterNG
 * @notice Simple flat-rate mock of the Curve Router NG for adapter unit tests
 * @dev Ignores the route/swap_params/pools contents for pricing; applies a configurable
 *      (tokenIn, tokenOut) exchange rate (1e18 basis, default 1:1). Stores the last-seen
 *      arguments in public fields so tests can assert the adapter passed them through
 *      unchanged. Must be pre-funded with output tokens in test setUp.
 */
contract MockCurveRouterNG is ICurveRouterNG {
    using SafeERC20 for IERC20;

    /// @notice Exchange rates: tokenIn => tokenOut => rate (1e18 = 1:1)
    mapping(address => mapping(address => uint256)) public exchangeRates;

    /// @notice Whether an exchange rate has been explicitly set
    mapping(address => mapping(address => bool)) public rateSet;

    /// @notice Last-seen route array (for pass-through assertions)
    address[11] public lastRoute;

    /// @notice Last-seen swap params matrix (for pass-through assertions)
    uint256[5][5] public lastSwapParams;

    /// @notice Last-seen pools array (for pass-through assertions)
    address[5] public lastPools;

    /// @notice Last-seen amount
    uint256 public lastAmount;

    /// @notice Last-seen expected (minimum) output
    uint256 public lastExpected;

    /// @notice Last-seen receiver
    address public lastReceiver;

    /// @notice Last-seen msg.sender for the call
    address public lastCaller;

    /**
     * @notice Set a 1e18-basis exchange rate for a token pair
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param rate The exchange rate (1e18 = 1:1)
     */
    function setExchangeRate(address tokenIn, address tokenOut, uint256 rate) external {
        exchangeRates[tokenIn][tokenOut] = rate;
        rateSet[tokenIn][tokenOut] = true;
    }

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

        // Resolve tokenIn and tokenOut from the route (first and last non-zero slots)
        address tokenIn = _route[0];
        address tokenOut;
        for (uint256 i = 0; i < 11; i++) {
            if (_route[i] != address(0)) {
                tokenOut = _route[i];
            }
        }

        // Apply configured exchange rate (default 1:1)
        uint256 rate = rateSet[tokenIn][tokenOut] ? exchangeRates[tokenIn][tokenOut] : 1e18;
        uint256 amountOut = (_amount * rate) / 1e18;

        require(amountOut >= _expected, "MockCurveRouterNG: insufficient output amount");

        // Pull tokenIn from caller and send tokenOut to receiver
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(tokenOut).safeTransfer(_receiver, amountOut);

        return amountOut;
    }
}
