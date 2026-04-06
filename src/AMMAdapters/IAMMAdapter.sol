// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IAMMAdapter
 * @notice Generic interface for AMM swap adapters
 * @dev Concrete implementations wrap specific DEX protocols (Uniswap, Curve, etc.)
 *      to provide a unified swap interface for yield strategies that need to buy/sell
 *      vault tokens on the open market instead of direct deposit/withdraw.
 */
interface IAMMAdapter {
    /**
     * @notice Swap tokenIn for tokenOut via the underlying AMM
     * @param tokenIn The token to sell
     * @param tokenOut The token to buy
     * @param amountIn The amount of tokenIn to sell
     * @param minAmountOut The minimum acceptable amount of tokenOut (slippage protection)
     * @return amountOut The actual amount of tokenOut received
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
}
