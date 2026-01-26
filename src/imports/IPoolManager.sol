// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title PoolId
 * @notice Type for Uniswap V4 pool identification
 */
type PoolId is bytes32;

/**
 * @title PoolKey
 * @notice Structure representing a Uniswap V4 pool configuration
 */
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/**
 * @title IPoolManager
 * @notice Simplified interface for Uniswap V4 PoolManager
 * @dev This is a minimal interface covering only the functionality needed for UniV4StableYieldStrategy
 */
interface IPoolManager {
    /// @notice Parameters for modifying liquidity
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }

    /// @notice Parameters for swapping
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Result of a liquidity modification
    struct BalanceDelta {
        int128 amount0;
        int128 amount1;
    }

    /**
     * @notice Modify liquidity for a position
     * @param key The pool key
     * @param params The modification parameters
     * @param hookData Data to pass to hooks
     * @return delta The balance delta (amounts owed/received)
     */
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta memory delta);

    /**
     * @notice Swap tokens in a pool
     * @param key The pool key
     * @param params The swap parameters
     * @param hookData Data to pass to hooks
     * @return delta The balance delta
     */
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta memory delta);

    /**
     * @notice Collect fees for a position
     * @param key The pool key
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @param salt Position salt
     * @return amount0 Amount of token0 fees collected
     * @return amount1 Amount of token1 fees collected
     */
    function collect(PoolKey calldata key, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Get position information
     * @param poolId The pool ID
     * @param owner The position owner
     * @param tickLower The lower tick
     * @param tickUpper The upper tick
     * @param salt Position salt
     * @return liquidity The position liquidity
     * @return feeGrowthInside0LastX128 Fee growth for token0
     * @return feeGrowthInside1LastX128 Fee growth for token1
     */
    function getPosition(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);

    /**
     * @notice Get the current sqrt price of a pool
     * @param poolId The pool ID
     * @return sqrtPriceX96 The current sqrt price
     */
    function getSqrtPriceX96(PoolId poolId) external view returns (uint160 sqrtPriceX96);

    /**
     * @notice Get the current tick of a pool
     * @param poolId The pool ID
     * @return tick The current tick
     */
    function getCurrentTick(PoolId poolId) external view returns (int24 tick);

    /**
     * @notice Settle a currency balance
     * @param currency The currency address
     * @return paid The amount paid
     */
    function settle(address currency) external payable returns (uint256 paid);

    /**
     * @notice Take currency from the pool manager
     * @param currency The currency address
     * @param to The recipient
     * @param amount The amount to take
     */
    function take(address currency, address to, uint256 amount) external;

    /**
     * @notice Sync a currency balance
     * @param currency The currency address
     */
    function sync(address currency) external;
}

/**
 * @title PoolIdLibrary
 * @notice Library for working with PoolId types
 */
library PoolIdLibrary {
    function toId(PoolKey memory key) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(key)));
    }
}
