// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../AYieldStrategy.sol";
import "../imports/IPoolManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UniV4StableYieldStrategy
 * @notice Oracle-free yield strategy for Uniswap V4 stable pools
 * @dev Extends AYieldStrategy to provide liquidity to a V4 stable pool and collect fees as yield.
 *
 * KEY DESIGN DECISIONS:
 * 1. Oracle-free: Assumes 1:1 price relationship between stablecoins (with slippage tolerance)
 * 2. No user withdrawals: Principal only exits via admin migration
 * 3. Single-token interface: Accepts deposit token, returns yield in deposit token
 * 4. Supports any decimal configuration (6/6, 18/18, 6/18, 18/6)
 * 5. Configurable tick range reused for all deposits
 * 6. tolerableLoss parameter for migration safety
 */
contract UniV4StableYieldStrategy is AYieldStrategy {
    using SafeERC20 for IERC20;

    // ============ TYPE DEFINITIONS ============

    /// @notice Position salt for V4 position identification
    bytes32 public constant POSITION_SALT = bytes32(0);

    // ============ STATE VARIABLES ============

    /// @notice The deposit token (the token users deposit, e.g., USDC)
    IERC20 public immutable depositToken;

    /// @notice The paired token (the second token in the V4 pool, e.g., USDT)
    IERC20 public immutable pairedToken;

    /// @notice Decimals for the deposit token
    uint8 public immutable depositTokenDecimals;

    /// @notice Decimals for the paired token
    uint8 public immutable pairedTokenDecimals;

    /// @notice The Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice The pool key identifying the V4 pool
    PoolKey public poolKey;

    /// @notice The pool ID derived from the pool key
    PoolId public immutable poolId;

    /// @notice Lower tick of the liquidity position
    int24 public immutable tickLower;

    /// @notice Upper tick of the liquidity position
    int24 public immutable tickUpper;

    /// @notice Slippage tolerance in basis points (e.g., 50 = 0.5%)
    uint24 public slippageTolerance;

    /// @notice Maximum allowed loss during migration (in deposit token units)
    uint256 public tolerableLoss;

    /// @notice Total liquidity owned in the V4 position
    uint128 public liquidityPosition;

    /// @notice Total deposit token received (principal tracking)
    uint256 public totalDeposited;

    /// @notice Mapping to track deposits per recipient (for single-depositor model, typically just the client)
    mapping(address => uint256) private clientDeposits;

    // ============ CONSTANTS ============

    /// @notice Maximum slippage tolerance (1% = 100 bps)
    uint24 public constant MAX_SLIPPAGE_TOLERANCE = 100;

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Precision for internal calculations (18 decimals)
    uint256 private constant PRECISION = 1e18;

    // ============ EVENTS ============

    event Deposited(address indexed client, address indexed recipient, uint256 amount, uint128 liquidityAdded);
    event YieldCollected(address indexed collector, uint256 depositTokenAmount, uint256 pairedTokenAmount);
    event Migrated(address indexed newStrategy, uint256 amountMigrated, uint256 actualLoss);
    event SlippageToleranceUpdated(uint24 oldTolerance, uint24 newTolerance);
    event TolerableLossUpdated(uint256 oldTolerance, uint256 newTolerance);

    // ============ ERRORS ============

    error InvalidToken();
    error WithdrawalsDisabled();
    error SlippageExceeded(uint256 expected, uint256 actual);
    error MigrationLossExceedsTolerance(uint256 actualLoss, uint256 tolerableLoss);
    error SlippageToleranceTooHigh(uint24 requested, uint24 maximum);
    error InvalidPoolConfiguration();
    error InsufficientLiquidity();

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initialize the UniV4StableYieldStrategy
     * @param _owner The owner of the contract
     * @param _depositToken The token users deposit
     * @param _pairedToken The second token in the V4 pool
     * @param _poolManager The V4 PoolManager address
     * @param _poolKey The pool key configuration
     * @param _tickLower Lower tick for liquidity position
     * @param _tickUpper Upper tick for liquidity position
     * @param _slippageTolerance Initial slippage tolerance in basis points
     * @param _tolerableLoss Initial tolerable loss for migrations
     */
    constructor(
        address _owner,
        address _depositToken,
        address _pairedToken,
        address _poolManager,
        PoolKey memory _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint24 _slippageTolerance,
        uint256 _tolerableLoss
    ) AYieldStrategy(_owner) {
        require(_depositToken != address(0), "UniV4StableYieldStrategy: deposit token cannot be zero address");
        require(_pairedToken != address(0), "UniV4StableYieldStrategy: paired token cannot be zero address");
        require(_poolManager != address(0), "UniV4StableYieldStrategy: pool manager cannot be zero address");
        require(_slippageTolerance <= MAX_SLIPPAGE_TOLERANCE, "UniV4StableYieldStrategy: slippage tolerance too high");
        require(_tickLower < _tickUpper, "UniV4StableYieldStrategy: invalid tick range");

        depositToken = IERC20(_depositToken);
        pairedToken = IERC20(_pairedToken);
        depositTokenDecimals = IERC20Metadata(_depositToken).decimals();
        pairedTokenDecimals = IERC20Metadata(_pairedToken).decimals();
        poolManager = IPoolManager(_poolManager);
        poolKey = _poolKey;
        poolId = PoolIdLibrary.toId(_poolKey);
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        slippageTolerance = _slippageTolerance;
        tolerableLoss = _tolerableLoss;

        // Pre-approve poolManager for both tokens
        IERC20(_depositToken).approve(_poolManager, type(uint256).max);
        IERC20(_pairedToken).approve(_poolManager, type(uint256).max);
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Deposit tokens and add liquidity to V4 pool
     * @param token The token to deposit (must be depositToken)
     * @param amount The amount to deposit
     * @param recipient The address that will own the deposit
     */
    function deposit(address token, uint256 amount, address recipient)
        external
        override
        onlyAuthorizedClient
        nonReentrant
        whenNotPaused
    {
        if (token != address(depositToken)) revert InvalidToken();
        require(amount > 0, "UniV4StableYieldStrategy: amount must be greater than zero");
        require(recipient != address(0), "UniV4StableYieldStrategy: recipient cannot be zero address");

        // Transfer deposit token from client
        depositToken.safeTransferFrom(msg.sender, address(this), amount);

        // Swap ~50% to paired token
        uint256 halfAmount = amount / 2;
        uint256 remainingAmount = amount - halfAmount;

        uint256 pairedAmount = _swapWithSlippageCheck(depositToken, pairedToken, halfAmount);

        // Add liquidity to V4 pool
        uint128 liquidityAdded = _addLiquidity(remainingAmount, pairedAmount);

        // Update state
        liquidityPosition += liquidityAdded;
        totalDeposited += amount;
        clientDeposits[recipient] += amount;

        emit Deposited(msg.sender, recipient, amount, liquidityAdded);
    }

    /**
     * @notice Withdraw is disabled - use migration instead
     */
    function withdraw(address, uint256, address) external pure override {
        revert WithdrawalsDisabled();
    }

    /**
     * @notice Collect yield (fees) from the V4 position
     * @return totalYieldInDepositToken The total yield collected, converted to deposit token
     */
    function collectYield() external nonReentrant whenNotPaused returns (uint256 totalYieldInDepositToken) {
        (uint256 fees0, uint256 fees1) = _collectFees();

        // Determine which token is which based on pool key ordering
        uint256 depositTokenFees;
        uint256 pairedTokenFees;

        if (address(depositToken) == poolKey.currency0) {
            depositTokenFees = fees0;
            pairedTokenFees = fees1;
        } else {
            depositTokenFees = fees1;
            pairedTokenFees = fees0;
        }

        // Swap paired token fees to deposit token
        uint256 swappedAmount = 0;
        if (pairedTokenFees > 0) {
            swappedAmount = _swapWithSlippageCheck(pairedToken, depositToken, pairedTokenFees);
        }

        totalYieldInDepositToken = depositTokenFees + swappedAmount;

        // Transfer yield to caller
        if (totalYieldInDepositToken > 0) {
            depositToken.safeTransfer(msg.sender, totalYieldInDepositToken);
        }

        emit YieldCollected(msg.sender, depositTokenFees, pairedTokenFees);

        return totalYieldInDepositToken;
    }

    /**
     * @notice Get pending yield (uncollected fees)
     * @return depositTokenFees Uncollected fees in deposit token
     * @return pairedTokenFees Uncollected fees in paired token
     */
    function pendingYield() external view returns (uint256 depositTokenFees, uint256 pairedTokenFees) {
        (uint128 liquidity,,) =
            poolManager.getPosition(poolId, address(this), tickLower, tickUpper, POSITION_SALT);

        if (liquidity == 0) {
            return (0, 0);
        }

        // Note: In a real implementation, this would query the actual pending fees from V4
        // For this implementation, we return 0 as fees are collected via collect()
        return (0, 0);
    }

    /**
     * @notice Migrate all funds to a new strategy
     * @param newStrategy The address to migrate funds to
     */
    function migrate(address newStrategy) external onlyOwner nonReentrant {
        require(newStrategy != address(0), "UniV4StableYieldStrategy: new strategy cannot be zero address");

        // Remove all liquidity
        (uint256 depositOut, uint256 pairedOut) = _removeLiquidity(liquidityPosition);

        // Swap all paired tokens to deposit token
        uint256 swappedAmount = 0;
        if (pairedOut > 0) {
            swappedAmount = _swapWithSlippageCheck(pairedToken, depositToken, pairedOut);
        }

        uint256 totalRecovered = depositOut + swappedAmount;

        // Calculate loss
        uint256 actualLoss = 0;
        if (totalDeposited > totalRecovered) {
            actualLoss = totalDeposited - totalRecovered;
        }

        // Check loss tolerance
        if (actualLoss > tolerableLoss) {
            revert MigrationLossExceedsTolerance(actualLoss, tolerableLoss);
        }

        // Reset state
        liquidityPosition = 0;
        totalDeposited = 0;

        // Transfer to new strategy
        if (totalRecovered > 0) {
            depositToken.safeTransfer(newStrategy, totalRecovered);
        }

        emit Migrated(newStrategy, totalRecovered, actualLoss);
    }

    /**
     * @notice Set the slippage tolerance
     * @param newTolerance New slippage tolerance in basis points
     */
    function setSlippageTolerance(uint24 newTolerance) external onlyOwner {
        if (newTolerance > MAX_SLIPPAGE_TOLERANCE) {
            revert SlippageToleranceTooHigh(newTolerance, MAX_SLIPPAGE_TOLERANCE);
        }

        uint24 oldTolerance = slippageTolerance;
        slippageTolerance = newTolerance;

        emit SlippageToleranceUpdated(oldTolerance, newTolerance);
    }

    /**
     * @notice Set the tolerable loss for migrations
     * @param newTolerance New tolerable loss amount
     */
    function setTolerableLoss(uint256 newTolerance) external onlyOwner {
        uint256 oldTolerance = tolerableLoss;
        tolerableLoss = newTolerance;

        emit TolerableLossUpdated(oldTolerance, newTolerance);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get total deposits
     * @return The total amount of deposit tokens deposited
     */
    function totalDeposits() external view returns (uint256) {
        return totalDeposited;
    }

    /**
     * @notice Get principal balance for an account
     * @param token The token address (must be depositToken)
     * @param account The account to query
     * @return The principal balance
     */
    function principalOf(address token, address account) external view override returns (uint256) {
        if (token != address(depositToken)) revert InvalidToken();
        return clientDeposits[account];
    }

    /**
     * @notice Get total balance including yield for an account
     * @param token The token address (must be depositToken)
     * @param account The account to query
     * @return The total balance (principal + proportional yield)
     */
    function totalBalanceOf(address token, address account) external view override returns (uint256) {
        if (token != address(depositToken)) revert InvalidToken();

        uint256 principal = clientDeposits[account];
        if (principal == 0 || totalDeposited == 0) {
            return 0;
        }

        // Calculate proportional share of total position value
        uint256 totalValue = _estimateTotalValue();
        return (totalValue * principal) / totalDeposited;
    }

    /**
     * @notice Get balance (returns principal for backward compatibility)
     * @param token The token address
     * @param account The account to query
     * @return The principal balance
     */
    function balanceOf(address token, address account) external view override returns (uint256) {
        return this.principalOf(token, account);
    }

    /**
     * @notice Get the current liquidity position
     * @return The total liquidity in the V4 position
     */
    function getLiquidityPosition() external view returns (uint128) {
        return liquidityPosition;
    }

    /**
     * @notice Get the pool key configuration
     * @return The pool key
     */
    function getPoolKey() external view returns (PoolKey memory) {
        return poolKey;
    }

    // ============ INTERNAL VIRTUAL IMPLEMENTATIONS ============

    /**
     * @notice Emergency withdraw implementation
     * @param amount The amount to withdraw (in deposit token terms)
     */
    function _emergencyWithdraw(uint256 amount) internal override {
        // Calculate proportional liquidity to remove
        uint256 totalValue = _estimateTotalValue();
        if (totalValue == 0) return;

        uint128 liquidityToRemove = uint128((uint256(liquidityPosition) * amount) / totalValue);
        if (liquidityToRemove > liquidityPosition) {
            liquidityToRemove = liquidityPosition;
        }

        if (liquidityToRemove > 0) {
            (uint256 depositOut, uint256 pairedOut) = _removeLiquidity(liquidityToRemove);

            // Swap paired to deposit token
            uint256 swappedAmount = 0;
            if (pairedOut > 0) {
                swappedAmount = _swapWithSlippageCheck(pairedToken, depositToken, pairedOut);
            }

            uint256 totalOut = depositOut + swappedAmount;
            liquidityPosition -= liquidityToRemove;

            // Transfer to owner
            if (totalOut > 0) {
                depositToken.safeTransfer(owner(), totalOut);
            }
        }
    }

    /**
     * @notice Total withdraw implementation for two-phase withdrawal
     * @param token The token address
     * @param client The client address
     * @param amount The amount to withdraw
     */
    function _totalWithdraw(address token, address client, uint256 amount) internal override {
        if (token != address(depositToken)) revert InvalidToken();

        uint256 clientBalance = clientDeposits[client];
        if (clientBalance == 0 || totalDeposited == 0) return;

        // Calculate proportional liquidity
        uint128 liquidityToRemove = uint128((uint256(liquidityPosition) * clientBalance) / totalDeposited);
        if (liquidityToRemove > liquidityPosition) {
            liquidityToRemove = liquidityPosition;
        }

        if (liquidityToRemove > 0) {
            (uint256 depositOut, uint256 pairedOut) = _removeLiquidity(liquidityToRemove);

            // Swap paired to deposit token
            uint256 swappedAmount = 0;
            if (pairedOut > 0) {
                swappedAmount = _swapWithSlippageCheck(pairedToken, depositToken, pairedOut);
            }

            uint256 totalOut = depositOut + swappedAmount;

            // Update state
            liquidityPosition -= liquidityToRemove;
            totalDeposited -= clientBalance;
            clientDeposits[client] = 0;

            // Transfer to owner (for manual redistribution)
            if (totalOut > 0) {
                depositToken.safeTransfer(owner(), totalOut);
            }
        }
    }

    /**
     * @notice WithdrawFrom implementation for authorized surplus withdrawal
     * @param token The token address
     * @param client The client address
     * @param amount The amount to withdraw
     * @param recipient The recipient address
     */
    function _withdrawFrom(address token, address client, uint256 amount, address recipient) internal override {
        if (token != address(depositToken)) revert InvalidToken();

        uint256 principal = clientDeposits[client];
        uint256 totalBalance = this.totalBalanceOf(token, client);

        // Calculate available surplus
        uint256 surplus = totalBalance > principal ? totalBalance - principal : 0;

        require(
            amount <= surplus,
            "UniV4StableYieldStrategy: amount exceeds available surplus, use totalWithdrawal() for principal"
        );

        // Calculate proportional liquidity for the surplus amount
        uint256 totalValue = _estimateTotalValue();
        if (totalValue == 0) return;

        uint128 liquidityToRemove = uint128((uint256(liquidityPosition) * amount) / totalValue);
        if (liquidityToRemove > liquidityPosition) {
            liquidityToRemove = liquidityPosition;
        }

        if (liquidityToRemove > 0) {
            (uint256 depositOut, uint256 pairedOut) = _removeLiquidity(liquidityToRemove);

            // Swap paired to deposit token
            uint256 swappedAmount = 0;
            if (pairedOut > 0) {
                swappedAmount = _swapWithSlippageCheck(pairedToken, depositToken, pairedOut);
            }

            uint256 totalOut = depositOut + swappedAmount;
            liquidityPosition -= liquidityToRemove;

            // Transfer to recipient
            if (totalOut > 0) {
                depositToken.safeTransfer(recipient, totalOut);
            }
        }

        // Note: clientDeposits is NOT modified for surplus withdrawals
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Swap tokens with slippage check
     * @param tokenIn The input token
     * @param tokenOut The output token
     * @param amountIn The input amount
     * @return amountOut The output amount received
     */
    function _swapWithSlippageCheck(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;

        // Calculate minimum output based on 1:1 assumption with decimal normalization
        uint256 expectedOut = _normalizeDecimals(
            amountIn,
            address(tokenIn) == address(depositToken) ? depositTokenDecimals : pairedTokenDecimals,
            address(tokenOut) == address(depositToken) ? depositTokenDecimals : pairedTokenDecimals
        );

        uint256 minOut = (expectedOut * (BPS_DENOMINATOR - slippageTolerance)) / BPS_DENOMINATOR;

        // Determine swap direction
        bool zeroForOne = address(tokenIn) == poolKey.currency0;

        // Execute swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: 0 // No price limit for stable pools
        });

        IPoolManager.BalanceDelta memory delta = poolManager.swap(poolKey, params, "");

        // Calculate actual output
        if (zeroForOne) {
            amountOut = delta.amount1 > 0 ? uint256(int256(delta.amount1)) : 0;
        } else {
            amountOut = delta.amount0 > 0 ? uint256(int256(delta.amount0)) : 0;
        }

        if (amountOut < minOut) {
            revert SlippageExceeded(minOut, amountOut);
        }

        return amountOut;
    }

    /**
     * @notice Add liquidity to V4 pool
     * @param depositAmount Amount of deposit token
     * @param pairedAmount Amount of paired token
     * @return liquidityAdded Amount of liquidity added
     */
    function _addLiquidity(uint256 depositAmount, uint256 pairedAmount) internal returns (uint128 liquidityAdded) {
        // Normalize to 18 decimals for liquidity calculation
        uint256 normalizedDeposit = _toStandardDecimals(depositAmount, depositTokenDecimals);
        uint256 normalizedPaired = _toStandardDecimals(pairedAmount, pairedTokenDecimals);

        // Use minimum of both for balanced liquidity
        uint256 liquidityAmount = normalizedDeposit < normalizedPaired ? normalizedDeposit : normalizedPaired;

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(liquidityAmount),
            salt: POSITION_SALT
        });

        poolManager.modifyLiquidity(poolKey, params, "");

        return uint128(liquidityAmount);
    }

    /**
     * @notice Collect fees from V4 position
     * @return fees0 Amount of token0 fees
     * @return fees1 Amount of token1 fees
     */
    function _collectFees() internal returns (uint256 fees0, uint256 fees1) {
        return poolManager.collect(poolKey, tickLower, tickUpper, POSITION_SALT);
    }

    /**
     * @notice Remove liquidity from V4 position
     * @param liquidity Amount of liquidity to remove
     * @return depositOut Amount of deposit token received
     * @return pairedOut Amount of paired token received
     */
    function _removeLiquidity(uint128 liquidity) internal returns (uint256 depositOut, uint256 pairedOut) {
        if (liquidity == 0) return (0, 0);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(int128(liquidity)),
            salt: POSITION_SALT
        });

        IPoolManager.BalanceDelta memory delta = poolManager.modifyLiquidity(poolKey, params, "");

        // Determine which output is deposit vs paired based on pool ordering
        if (address(depositToken) == poolKey.currency0) {
            depositOut = delta.amount0 > 0 ? uint256(int256(delta.amount0)) : 0;
            pairedOut = delta.amount1 > 0 ? uint256(int256(delta.amount1)) : 0;
        } else {
            depositOut = delta.amount1 > 0 ? uint256(int256(delta.amount1)) : 0;
            pairedOut = delta.amount0 > 0 ? uint256(int256(delta.amount0)) : 0;
        }

        return (depositOut, pairedOut);
    }

    /**
     * @notice Normalize decimals between tokens
     * @param amount The amount to normalize
     * @param fromDecimals Source decimals
     * @param toDecimals Target decimals
     * @return normalized The normalized amount
     */
    function _normalizeDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals)
        internal
        pure
        returns (uint256 normalized)
    {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        } else {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
    }

    /**
     * @notice Convert to standard 18 decimals
     * @param amount The amount to convert
     * @param decimals The current decimals
     * @return The amount in 18 decimals
     */
    function _toStandardDecimals(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) {
            return amount;
        } else if (decimals > 18) {
            return amount / (10 ** (decimals - 18));
        } else {
            return amount * (10 ** (18 - decimals));
        }
    }

    /**
     * @notice Estimate total value of position in deposit token terms
     * @return totalValue The estimated total value
     */
    function _estimateTotalValue() internal view returns (uint256 totalValue) {
        if (liquidityPosition == 0) return 0;

        // For stable pools with 1:1 assumption, liquidity roughly equals value
        // Convert from 18 decimals to deposit token decimals
        uint256 liquidityIn18 = uint256(liquidityPosition);

        // Each unit of liquidity corresponds to ~2x value (deposit + paired)
        // So liquidity * 2 gives approximate total value in 18 decimals
        uint256 estimatedValue = liquidityIn18 * 2;

        // Convert to deposit token decimals
        if (depositTokenDecimals >= 18) {
            return estimatedValue * (10 ** (depositTokenDecimals - 18));
        } else {
            return estimatedValue / (10 ** (18 - depositTokenDecimals));
        }
    }
}
