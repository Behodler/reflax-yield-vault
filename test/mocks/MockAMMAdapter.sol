// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/AMMAdapters/IAMMAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockAMMAdapter
 * @notice Mock AMM adapter for testing with configurable exchange rates
 * @dev Simulates AMM swap behavior. Must hold reserves of output tokens (pre-minted in tests).
 *      Exchange rates are configurable per token pair in 1e18 basis.
 */
contract MockAMMAdapter is IAMMAdapter {
    using SafeERC20 for IERC20;

    /// @notice Exchange rates: tokenIn => tokenOut => rate (1e18 = 1:1)
    mapping(address => mapping(address => uint256)) public exchangeRates;

    /// @notice Whether an exchange rate has been explicitly set
    mapping(address => mapping(address => bool)) public rateSet;

    /// @notice Number of times swap() has been called (test instrumentation)
    uint256 public swapCount;

    /// @notice The amountIn of the most recent swap() call (test instrumentation)
    uint256 public lastAmountIn;

    /**
     * @notice Set the exchange rate for a token pair
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param rate The exchange rate in 1e18 basis (e.g., 1e18 = 1:1, 2e18 = 1:2)
     */
    function setExchangeRate(address tokenIn, address tokenOut, uint256 rate) external {
        exchangeRates[tokenIn][tokenOut] = rate;
        rateSet[tokenIn][tokenOut] = true;
    }

    /**
     * @notice Swap tokenIn for tokenOut using configured exchange rate
     * @param tokenIn The token to sell
     * @param tokenOut The token to buy
     * @param amountIn The amount of tokenIn to sell
     * @param minAmountOut The minimum acceptable amount of tokenOut
     * @return amountOut The actual amount of tokenOut sent to caller
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        swapCount++;
        lastAmountIn = amountIn;

        // Get exchange rate (default 1:1 if not set)
        uint256 rate = rateSet[tokenIn][tokenOut] ? exchangeRates[tokenIn][tokenOut] : 1e18;

        // Calculate output amount
        amountOut = (amountIn * rate) / 1e18;

        // Enforce slippage protection
        require(amountOut >= minAmountOut, "MockAMMAdapter: insufficient output amount");

        // Take tokenIn from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Send tokenOut to caller
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        return amountOut;
    }
}
