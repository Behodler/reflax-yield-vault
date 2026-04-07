// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockCurveStableSwapNGPool
 * @notice Mock 2-coin Curve Stableswap-NG pool for integration tests
 * @dev Exposes a subset of the real Stableswap-NG interface sufficient for the route-walking
 *      `MockCurveRouterNGRouted` to drive multi-hop swaps. Supports a configurable 1e18-basis
 *      exchange rate and an optional basis-points slippage deduction so tests can simulate
 *      price deterioration during a hop. Must be pre-funded with both tokens in test setUp.
 */
contract MockCurveStableSwapNGPool {
    using SafeERC20 for IERC20;

    /// @notice The two coins held by the pool (coin index 0 and 1)
    address[2] private _coins;

    /// @notice Exchange rate from coin0 to coin1 (1e18 = 1:1)
    uint256 public exchangeRate;

    /// @notice Slippage deducted from the output in basis points (e.g. 100 = 1%)
    uint256 public slippageBps;

    /**
     * @notice Initialize the pool with its two coin addresses
     * @param coin0 Address of coin index 0
     * @param coin1 Address of coin index 1
     */
    constructor(address coin0, address coin1) {
        _coins[0] = coin0;
        _coins[1] = coin1;
        exchangeRate = 1e18; // Default 1:1
        slippageBps = 0;
    }

    /**
     * @notice Return the coin at the specified index
     * @param i Coin index (0 or 1)
     * @return Address of the coin
     */
    function coins(uint256 i) external view returns (address) {
        require(i < 2, "MockCurveStableSwapNGPool: invalid coin index");
        return _coins[i];
    }

    /**
     * @notice Set the 1e18-basis exchange rate from coin0 to coin1
     * @param rate The rate (1e18 = 1:1, 2e18 = 1:2, etc.)
     */
    function setExchangeRate(uint256 rate) external {
        exchangeRate = rate;
    }

    /**
     * @notice Set a basis-points slippage deduction applied to the output
     * @param bps Slippage in basis points (e.g. 100 = 1%)
     */
    function setSlippageBps(uint256 bps) external {
        require(bps <= 10000, "MockCurveStableSwapNGPool: slippage exceeds 100%");
        slippageBps = bps;
    }

    /**
     * @notice Execute an exchange of `dx` of coin `i` for coin `j`
     * @param i Input coin index
     * @param j Output coin index
     * @param dx Amount of input coin to sell
     * @param min_dy Minimum acceptable amount of output coin
     * @return dy Amount of output coin sent to the caller
     */
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 dy) {
        require(i != j, "MockCurveStableSwapNGPool: i == j");
        require(i == 0 || i == 1, "MockCurveStableSwapNGPool: invalid i");
        require(j == 0 || j == 1, "MockCurveStableSwapNGPool: invalid j");

        address tokenIn = _coins[uint256(uint128(i))];
        address tokenOut = _coins[uint256(uint128(j))];

        // Compute output: apply exchange rate for coin0 -> coin1, inverse for coin1 -> coin0
        uint256 rawOut;
        if (i == 0 && j == 1) {
            rawOut = (dx * exchangeRate) / 1e18;
        } else {
            // j == 0, i == 1
            rawOut = (dx * 1e18) / exchangeRate;
        }

        // Apply slippage deduction
        dy = (rawOut * (10000 - slippageBps)) / 10000;

        require(dy >= min_dy, "MockCurveStableSwapNGPool: dy < min_dy");

        // Pull input from caller, send output to caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), dx);
        IERC20(tokenOut).safeTransfer(msg.sender, dy);
    }
}
