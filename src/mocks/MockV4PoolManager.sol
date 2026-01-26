// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../imports/IPoolManager.sol";
import "./MockERC20.sol";

/**
 * @title MockV4PoolManager
 * @notice Mock implementation of Uniswap V4 PoolManager for testing UniV4StableYieldStrategy
 * @dev Simulates a V4 pool with configurable stable pool behavior for testing different decimal configurations
 */
contract MockV4PoolManager is IPoolManager {
    // Pool state
    struct PoolState {
        uint128 liquidity;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
    }

    // Position state
    struct Position {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    // Storage
    mapping(PoolId => PoolState) public pools;
    mapping(bytes32 => Position) public positions;
    mapping(PoolId => PoolKey) public poolKeys;

    // Token addresses for the pool
    address public token0;
    address public token1;

    // Decimals for testing
    uint8 public token0Decimals;
    uint8 public token1Decimals;

    // Slippage simulation
    uint256 public swapSlippageBps; // Basis points of slippage on swaps

    // Fee simulation
    uint256 public simulatedFees0;
    uint256 public simulatedFees1;

    // Events for testing
    event LiquidityModified(
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta,
        int128 amount0,
        int128 amount1
    );
    event Swapped(bool zeroForOne, int256 amountSpecified, int128 amount0, int128 amount1);
    event FeesCollected(address indexed owner, uint256 amount0, uint256 amount1);

    constructor(address _token0, address _token1, uint8 _token0Decimals, uint8 _token1Decimals) {
        token0 = _token0;
        token1 = _token1;
        token0Decimals = _token0Decimals;
        token1Decimals = _token1Decimals;

        // Initialize with 1:1 price (accounting for decimals)
        // sqrtPriceX96 = sqrt(price) * 2^96
        // For 1:1 price between tokens of same decimals, sqrtPriceX96 = 2^96
        // Adjust for decimal differences if needed
    }

    /**
     * @notice Initialize a pool for testing
     */
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external {
        PoolId poolId = PoolIdLibrary.toId(key);
        poolKeys[poolId] = key;
        pools[poolId] = PoolState({
            liquidity: 0,
            sqrtPriceX96: sqrtPriceX96,
            tick: 0, // Simplified for stable pools
            feeGrowthGlobal0X128: 0,
            feeGrowthGlobal1X128: 0
        });
    }

    /**
     * @notice Modify liquidity for a position
     */
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        external
        override
        returns (BalanceDelta memory delta)
    {
        PoolId poolId = PoolIdLibrary.toId(key);
        bytes32 positionKey = _getPositionKey(msg.sender, params.tickLower, params.tickUpper, params.salt);

        Position storage position = positions[positionKey];

        if (params.liquidityDelta > 0) {
            // Adding liquidity
            uint256 liquidity = uint256(int256(params.liquidityDelta));

            // For stable pools, we assume roughly equal amounts of both tokens
            // Normalize for decimal differences
            uint256 amount0 = _normalizeForDecimals(liquidity, token0Decimals);
            uint256 amount1 = _normalizeForDecimals(liquidity, token1Decimals);

            delta.amount0 = -int128(int256(amount0)); // Negative means tokens owed by user
            delta.amount1 = -int128(int256(amount1));

            // Transfer tokens from user
            MockERC20(token0).transferFrom(msg.sender, address(this), amount0);
            MockERC20(token1).transferFrom(msg.sender, address(this), amount1);

            position.liquidity += uint128(liquidity);
            pools[poolId].liquidity += uint128(liquidity);
        } else if (params.liquidityDelta < 0) {
            // Removing liquidity
            uint256 liquidity = uint256(-int256(params.liquidityDelta));

            // Calculate amounts to return
            uint256 amount0 = _normalizeForDecimals(liquidity, token0Decimals);
            uint256 amount1 = _normalizeForDecimals(liquidity, token1Decimals);

            delta.amount0 = int128(int256(amount0)); // Positive means tokens owed to user
            delta.amount1 = int128(int256(amount1));

            // Transfer tokens to user
            MockERC20(token0).transfer(msg.sender, amount0);
            MockERC20(token1).transfer(msg.sender, amount1);

            position.liquidity -= uint128(liquidity);
            pools[poolId].liquidity -= uint128(liquidity);
        }

        emit LiquidityModified(
            msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta, delta.amount0, delta.amount1
        );

        return delta;
    }

    /**
     * @notice Swap tokens
     */
    function swap(PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        override
        returns (BalanceDelta memory delta)
    {
        // Simplified 1:1 swap with optional slippage
        uint256 amountIn;
        uint256 amountOut;

        if (params.amountSpecified > 0) {
            // Exact input swap
            amountIn = uint256(params.amountSpecified);
            // Normalize for decimal differences and apply slippage
            if (params.zeroForOne) {
                // token0 -> token1
                amountOut = _convertWithDecimals(amountIn, token0Decimals, token1Decimals);
                amountOut = _applySlippage(amountOut);

                MockERC20(token0).transferFrom(msg.sender, address(this), amountIn);
                MockERC20(token1).transfer(msg.sender, amountOut);

                delta.amount0 = -int128(int256(amountIn));
                delta.amount1 = int128(int256(amountOut));
            } else {
                // token1 -> token0
                amountOut = _convertWithDecimals(amountIn, token1Decimals, token0Decimals);
                amountOut = _applySlippage(amountOut);

                MockERC20(token1).transferFrom(msg.sender, address(this), amountIn);
                MockERC20(token0).transfer(msg.sender, amountOut);

                delta.amount0 = int128(int256(amountOut));
                delta.amount1 = -int128(int256(amountIn));
            }
        } else {
            // Exact output swap
            amountOut = uint256(-params.amountSpecified);
            if (params.zeroForOne) {
                // token0 -> token1 (exact output)
                amountIn = _convertWithDecimals(amountOut, token1Decimals, token0Decimals);
                amountIn = _applySlippageReverse(amountIn);

                MockERC20(token0).transferFrom(msg.sender, address(this), amountIn);
                MockERC20(token1).transfer(msg.sender, amountOut);

                delta.amount0 = -int128(int256(amountIn));
                delta.amount1 = int128(int256(amountOut));
            } else {
                // token1 -> token0 (exact output)
                amountIn = _convertWithDecimals(amountOut, token0Decimals, token1Decimals);
                amountIn = _applySlippageReverse(amountIn);

                MockERC20(token1).transferFrom(msg.sender, address(this), amountIn);
                MockERC20(token0).transfer(msg.sender, amountOut);

                delta.amount0 = int128(int256(amountOut));
                delta.amount1 = -int128(int256(amountIn));
            }
        }

        emit Swapped(params.zeroForOne, params.amountSpecified, delta.amount0, delta.amount1);

        return delta;
    }

    /**
     * @notice Collect fees
     */
    function collect(PoolKey calldata, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 positionKey = _getPositionKey(msg.sender, tickLower, tickUpper, salt);
        Position storage position = positions[positionKey];

        amount0 = uint256(position.tokensOwed0);
        amount1 = uint256(position.tokensOwed1);

        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;

        if (amount0 > 0) {
            MockERC20(token0).transfer(msg.sender, amount0);
        }
        if (amount1 > 0) {
            MockERC20(token1).transfer(msg.sender, amount1);
        }

        emit FeesCollected(msg.sender, amount0, amount1);

        return (amount0, amount1);
    }

    /**
     * @notice Get position information
     */
    function getPosition(PoolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        override
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)
    {
        bytes32 positionKey = _getPositionKey(owner, tickLower, tickUpper, salt);
        Position storage position = positions[positionKey];

        return (position.liquidity, position.feeGrowthInside0LastX128, position.feeGrowthInside1LastX128);
    }

    function getSqrtPriceX96(PoolId poolId) external view override returns (uint160) {
        return pools[poolId].sqrtPriceX96;
    }

    function getCurrentTick(PoolId poolId) external view override returns (int24) {
        return pools[poolId].tick;
    }

    function settle(address) external payable override returns (uint256) {
        return msg.value;
    }

    function take(address currency, address to, uint256 amount) external override {
        MockERC20(currency).transfer(to, amount);
    }

    function sync(address) external override {}

    // ============ TEST HELPER FUNCTIONS ============

    /**
     * @notice Simulate fee accrual for a position
     */
    function simulateFees(address owner, int24 tickLower, int24 tickUpper, bytes32 salt, uint128 fees0, uint128 fees1)
        external
    {
        bytes32 positionKey = _getPositionKey(owner, tickLower, tickUpper, salt);
        Position storage position = positions[positionKey];

        position.tokensOwed0 += fees0;
        position.tokensOwed1 += fees1;
    }

    /**
     * @notice Set swap slippage for testing
     */
    function setSwapSlippage(uint256 slippageBps) external {
        swapSlippageBps = slippageBps;
    }

    /**
     * @notice Fund the pool with tokens for liquidity removal and swaps
     */
    function fundPool(uint256 amount0, uint256 amount1) external {
        if (amount0 > 0) {
            MockERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            MockERC20(token1).transferFrom(msg.sender, address(this), amount1);
        }
    }

    // ============ INTERNAL FUNCTIONS ============

    function _getPositionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

    function _normalizeForDecimals(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        // Normalize to the token's decimal representation
        // Assuming liquidity is in 18 decimals, scale to token decimals
        if (decimals >= 18) {
            return amount * (10 ** (decimals - 18));
        } else {
            return amount / (10 ** (18 - decimals));
        }
    }

    function _convertWithDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals)
        internal
        pure
        returns (uint256)
    {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        } else {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
    }

    function _applySlippage(uint256 amount) internal view returns (uint256) {
        if (swapSlippageBps == 0) return amount;
        return amount * (10000 - swapSlippageBps) / 10000;
    }

    function _applySlippageReverse(uint256 amount) internal view returns (uint256) {
        if (swapSlippageBps == 0) return amount;
        return amount * 10000 / (10000 - swapSlippageBps);
    }
}
