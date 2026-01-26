// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../AYieldStrategy.sol";
import "../imports/IAutoPool.sol";
import "../imports/IMainRewarder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AutoPoolYieldStrategy
 * @notice Generic yield strategy implementation for Auto Finance autopools (autoDOLA, autoUSD, autoETH, etc.)
 * @dev Extends AYieldStrategy.sol to provide underlying token deposits with automatic autopool staking and TOKE reward generation
 */
contract AutoPoolYieldStrategy is AYieldStrategy {
    using SafeERC20 for IERC20;

    // ============ STATE VARIABLES ============

    /// @notice The underlying token contract (DOLA, USDC, WETH, etc.)
    IERC20 public immutable underlyingToken;

    /// @notice The TOKE token contract
    IERC20 public immutable tokeToken;

    /// @notice The autopool vault contract (ERC4626)
    IAutoPool public immutable autoPoolVault;

    /// @notice The MainRewarder contract for TOKE rewards
    IMainRewarder public immutable mainRewarder;

    /// @notice Mapping to track each client's underlying token balance equivalent
    mapping(address => mapping(address => uint256)) private clientBalances;

    /// @notice Total underlying token deposited across all clients for a token
    mapping(address => uint256) private totalDeposited;

    // ============ EVENTS ============

    /**
     * @notice Emitted when underlying token is deposited and staked in autopool
     * @param token The token address
     * @param client The client address making the deposit
     * @param recipient The recipient of the deposited tokens
     * @param amount The amount of underlying token deposited
     * @param sharesReceived The amount of autopool shares received
     */
    event Deposited(
        address indexed token, address indexed client, address indexed recipient, uint256 amount, uint256 sharesReceived
    );

    /**
     * @notice Emitted when autopool shares are withdrawn and converted to underlying token
     * @param token The token address
     * @param client The client address making the withdrawal
     * @param recipient The recipient of the withdrawn tokens
     * @param amount The amount of underlying token withdrawn
     * @param sharesBurned The amount of autopool shares burned
     */
    event Withdrawn(
        address indexed token, address indexed client, address indexed recipient, uint256 amount, uint256 sharesBurned
    );

    /**
     * @notice Emitted when TOKE rewards are claimed by the owner
     * @param recipient The address that received the TOKE rewards
     * @param amount The amount of TOKE rewards claimed
     */
    event TokeRewardsClaimed(address indexed recipient, uint256 amount);

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initialize the AutoPoolYieldStrategy with required contract addresses
     * @param _owner The owner of the vault
     * @param _underlyingToken The underlying token address (DOLA, USDC, WETH, etc.)
     * @param _tokeToken The TOKE token address
     * @param _autoPoolVault The autopool vault address (autoDOLA, autoUSD, autoETH, etc.)
     * @param _mainRewarder The MainRewarder address
     */
    constructor(
        address _owner,
        address _underlyingToken,
        address _tokeToken,
        address _autoPoolVault,
        address _mainRewarder
    ) AYieldStrategy(_owner) {
        require(_underlyingToken != address(0), "AutoPoolYieldStrategy: underlying token cannot be zero address");
        require(_tokeToken != address(0), "AutoPoolYieldStrategy: TOKE token cannot be zero address");
        require(_autoPoolVault != address(0), "AutoPoolYieldStrategy: autopool vault cannot be zero address");
        require(_mainRewarder != address(0), "AutoPoolYieldStrategy: MainRewarder cannot be zero address");

        underlyingToken = IERC20(_underlyingToken);
        tokeToken = IERC20(_tokeToken);
        autoPoolVault = IAutoPool(_autoPoolVault);
        mainRewarder = IMainRewarder(_mainRewarder);

        // Approve autopool vault to spend underlying tokens
        underlyingToken.approve(_autoPoolVault, type(uint256).max);

        // Approve MainRewarder to spend autopool shares
        IERC20(_autoPoolVault).approve(_mainRewarder, type(uint256).max);
    }

    // ============ PUBLIC VIEW FUNCTIONS ============

    /**
     * @notice Returns the underlying token address this strategy accepts
     * @return The address of the underlying token (DOLA, USDC, etc.)
     */
    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    /**
     * @notice Get principal balance (amount deposited, excluding yield)
     * @param token The token address
     * @param account The account address
     * @return The principal amount deposited (excluding yield)
     */
    function principalOf(address token, address account) external view override returns (uint256) {
        require(token == address(underlyingToken), "AutoPoolYieldStrategy: only underlying token supported");
        return clientBalances[token][account];
    }

    /**
     * @notice Get total balance including proportional yield
     * @param token The token address
     * @param account The account address
     * @return The total balance including principal and accumulated yield
     * @dev Calculates user's proportional share of total vault value
     */
    function totalBalanceOf(address token, address account) external view override returns (uint256) {
        require(token == address(underlyingToken), "AutoPoolYieldStrategy: only underlying token supported");

        uint256 principal = clientBalances[token][account];
        if (principal == 0 || totalDeposited[token] == 0) {
            return 0;
        }

        // Calculate proportional share of total vault value
        uint256 totalShares = mainRewarder.balanceOf(address(this));
        uint256 totalValue = autoPoolVault.convertToAssets(totalShares);

        // User's proportion: (userPrincipal / totalPrincipal) * totalValue
        return (totalValue * principal) / totalDeposited[token];
    }

    /**
     * @notice Get balance (returns principal for backward compatibility)
     * @param token The token address
     * @param account The account address
     * @return The principal balance
     * @dev DEPRECATED: Use principalOf() or totalBalanceOf() explicitly
     *      Kept for backward compatibility. Returns principal only.
     */
    function balanceOf(address token, address account) external view override returns (uint256) {
        return this.principalOf(token, account);
    }

    /**
     * @notice Get the total amount of underlying token deposited by all clients
     * @param token The token address
     * @return The total amount of underlying token deposited
     */
    function getTotalDeposited(address token) external view returns (uint256) {
        return totalDeposited[token];
    }

    /**
     * @notice Get the total autopool shares held by this vault
     * @return The total amount of autopool shares
     */
    function getTotalShares() external view returns (uint256) {
        return autoPoolVault.balanceOf(address(this));
    }

    /**
     * @notice Get the current TOKE rewards available for claiming
     * @return The amount of TOKE rewards earned
     */
    function getTokeRewards() external view returns (uint256) {
        return mainRewarder.earned(address(this));
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Deposit underlying tokens into the vault with automatic autopool staking
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to deposit
     * @param recipient The address that will own the deposited tokens
     * @dev Only authorized clients can call this function
     */
    function deposit(address token, uint256 amount, address recipient)
        external
        override
        onlyAuthorizedClient
        nonReentrant
        whenNotPaused
    {
        require(token == address(underlyingToken), "AutoPoolYieldStrategy: only underlying token supported");
        require(amount > 0, "AutoPoolYieldStrategy: amount must be greater than zero");
        require(recipient != address(0), "AutoPoolYieldStrategy: recipient cannot be zero address");

        // Transfer underlying token from client to vault
        underlyingToken.safeTransferFrom(msg.sender, address(this), amount);

        // Deposit underlying token into autopool vault to receive shares
        uint256 sharesBefore = autoPoolVault.balanceOf(address(this));
        uint256 sharesReceived = autoPoolVault.deposit(amount, address(this));
        uint256 sharesAfter = autoPoolVault.balanceOf(address(this));

        // Verify shares received
        require(sharesAfter == sharesBefore + sharesReceived, "AutoPoolYieldStrategy: share calculation mismatch");
        require(sharesReceived > 0, "AutoPoolYieldStrategy: no shares received");

        // Stake the autopool shares in MainRewarder to earn TOKE rewards
        mainRewarder.stake(address(this), sharesReceived);

        // Update client balance and total deposited
        clientBalances[token][recipient] += amount;
        totalDeposited[token] += amount;

        emit Deposited(token, msg.sender, recipient, amount, sharesReceived);
    }

    /**
     * @notice Withdraw underlying tokens from the vault
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to withdraw (principal only)
     * @param recipient The address that will receive the tokens
     * @dev Only authorized clients can call this function
     *      Withdraws only principal, leaving yield locked in the contract
     *      Uses ERC4626 convertToShares for standard compliance
     *      Caps amount to available principal to prevent dust-related reverts
     *
     *      SECURITY PROPERTIES:
     *      - Rounding favors protocol: clientBalances decremented by requested amount,
     *        not actual received amount. Any shortfall accumulates as protocol yield.
     *      - Yield-exclusion: convertToShares accounts for accrued yield, ensuring
     *        users receive only principal by redeeming fewer shares when yield present.
     *      - Dust handling: Amount capped to available balance prevents final withdrawal
     *        from reverting due to accumulated rounding differences.
     */
    function withdraw(address token, uint256 amount, address recipient)
        external
        override
        onlyAuthorizedClient
        nonReentrant
        whenNotPaused
    {
        require(token == address(underlyingToken), "AutoPoolYieldStrategy: only underlying token supported");
        require(amount > 0, "AutoPoolYieldStrategy: amount must be greater than zero");
        require(recipient != address(0), "AutoPoolYieldStrategy: recipient cannot be zero address");

        // Cap amount to available principal (prevents dust from blocking withdrawal)
        // This allows the final withdrawal to succeed even with minor rounding differences
        uint256 availablePrincipal = clientBalances[token][recipient];
        if (amount > availablePrincipal) {
            amount = availablePrincipal;
        }

        // Unstake ALL shares to ensure we have them available for withdrawal
        uint256 totalShares = mainRewarder.balanceOf(address(this));
        require(totalShares > 0, "AutoPoolYieldStrategy: no shares available");
        mainRewarder.withdraw(address(this), totalShares, false);

        // CRITICAL: Use ERC4626 standard convertToShares instead of manual calculation
        // convertToShares accounts for current share price, ensuring principal-only withdrawal
        // When yield accrues, shares become more valuable, so fewer shares needed for same amount
        // This automatically preserves yield-exclusion without manual proportion tracking
        uint256 sharesToRedeem = autoPoolVault.convertToShares(amount);
        uint256 availableShares = autoPoolVault.balanceOf(address(this));
        if (sharesToRedeem > availableShares) {
            sharesToRedeem = availableShares;
        }
        uint256 tokensReceived = autoPoolVault.redeem(sharesToRedeem, recipient, address(this));

        // CRITICAL FIX: Re-stake ALL remaining vault shares (yield preservation)
        // Query vault balance AFTER withdrawal to get actual remaining shares
        // This simple approach avoids calculation errors - just stake whatever's left
        uint256 leftoverShares = autoPoolVault.balanceOf(address(this));
        if (leftoverShares > 0) {
            mainRewarder.stake(address(this), leftoverShares);
        }

        // SECURITY: Update principal tracking by REQUESTED amount, not RECEIVED amount
        // This ensures rounding always favors the protocol, preventing exploitation
        // Any difference (amount - tokensReceived) accumulates as protocol-owned yield
        clientBalances[token][recipient] -= amount;
        totalDeposited[token] -= amount;

        emit Withdrawn(token, msg.sender, recipient, tokensReceived, sharesToRedeem);
    }

    /**
     * @notice Claim TOKE rewards earned from staking autopool shares
     * @param recipient The address that will receive the TOKE rewards
     * @dev Only the owner can call this function for security
     */
    function claimTokeRewards(address recipient) external onlyOwner whenNotPaused {
        require(recipient != address(0), "AutoPoolYieldStrategy: recipient cannot be zero address");

        uint256 rewardsBefore = tokeToken.balanceOf(address(this));
        bool success = mainRewarder.getReward(address(this), address(this), true);
        uint256 rewardsAfter = tokeToken.balanceOf(address(this));

        require(success, "AutoPoolYieldStrategy: TOKE reward claim failed");
        uint256 rewardsEarned = rewardsAfter - rewardsBefore;

        if (rewardsEarned > 0) {
            tokeToken.safeTransfer(recipient, rewardsEarned);
            emit TokeRewardsClaimed(recipient, rewardsEarned);
        }
    }

    // ============ INTERNAL VIRTUAL FUNCTION IMPLEMENTATIONS ============

    /**
     * @notice Internal emergency withdraw implementation
     * @param amount The amount of underlying tokens to withdraw
     * @dev Withdraws underlying tokens by unstaking and redeeming autopool shares
     */
    function _emergencyWithdraw(uint256 amount) internal override {
        uint256 totalShares = mainRewarder.balanceOf(address(this));
        require(totalShares > 0, "AutoPoolYieldStrategy: no shares to withdraw");

        // Calculate how many shares needed for the requested amount
        uint256 totalAssets = autoPoolVault.convertToAssets(totalShares);
        uint256 sharesToWithdraw = totalShares;

        if (amount < totalAssets) {
            sharesToWithdraw = autoPoolVault.convertToShares(amount);
        }

        // Unstake from MainRewarder
        uint256 stakedShares = mainRewarder.balanceOf(address(this));
        if (stakedShares > 0) {
            uint256 toUnstake = sharesToWithdraw > stakedShares ? stakedShares : sharesToWithdraw;
            mainRewarder.withdraw(address(this), toUnstake, false);
        }

        // Redeem from autopool vault
        uint256 assetsReceived = autoPoolVault.redeem(sharesToWithdraw, address(this), address(this));

        // Transfer to owner
        uint256 actualAmount = assetsReceived < amount ? assetsReceived : amount;
        underlyingToken.safeTransfer(owner(), actualAmount);
    }

    /**
     * @notice Internal total withdraw implementation for emergency fund migration
     * @param token The token address (must be underlying token)
     * @param client The client address whose tokens to withdraw
     * @param amount The amount to withdraw (from cached balance)
     */
    function _totalWithdraw(address token, address client, uint256 amount) internal override {
        require(token == address(underlyingToken), "AutoPoolYieldStrategy: only underlying token supported");
        require(amount > 0, "AutoPoolYieldStrategy: amount must be greater than zero");

        // Calculate proportional shares to withdraw
        uint256 totalShares = mainRewarder.balanceOf(address(this));
        if (totalShares == 0 || totalDeposited[token] == 0) {
            return; // Nothing to withdraw
        }

        uint256 clientStoredBalance = clientBalances[token][client];
        uint256 sharesToWithdraw = (totalShares * clientStoredBalance) / totalDeposited[token];

        if (sharesToWithdraw > 0) {
            // Unstake from MainRewarder
            uint256 stakedShares = mainRewarder.balanceOf(address(this));
            if (stakedShares > 0) {
                uint256 toUnstake = sharesToWithdraw > stakedShares ? stakedShares : sharesToWithdraw;
                mainRewarder.withdraw(address(this), toUnstake, false);
            }

            // Redeem from autopool vault
            uint256 assetsReceived = autoPoolVault.redeem(sharesToWithdraw, address(this), address(this));

            // Update balances
            clientBalances[token][client] = 0;
            totalDeposited[token] -= clientStoredBalance;

            // Transfer to owner (for manual redistribution)
            underlyingToken.safeTransfer(owner(), assetsReceived);
        }
    }

    /**
     * @notice Internal withdrawFrom implementation for authorized surplus withdrawal
     * @param token The token address (must be underlying token)
     * @param client The client address whose balance to withdraw from
     * @param amount The amount to withdraw (MUST be <= available surplus)
     * @param recipient The address that will receive the withdrawn tokens
     * @dev Allows authorized withdrawers to extract surplus (yield) without touching principal.
     *      This function is EXCLUSIVELY for surplus extraction and will revert if attempting
     *      to withdraw more than available yield. For full balance withdrawal including principal,
     *      use totalWithdrawal() which has proper timelock protection.
     *
     *      CRITICAL: Principal tracking (clientBalances) is NEVER modified by this function.
     *      Only surplus/yield can be withdrawn. This ensures principal remains accurate over time.
     */
    function _withdrawFrom(address token, address client, uint256 amount, address recipient) internal override {
        require(token == address(underlyingToken), "AutoPoolYieldStrategy: only underlying token supported");
        // Note: amount > 0 and recipient != address(0) checks are performed by parent AYieldStrategy

        // Get current balances
        uint256 principal = clientBalances[token][client];
        uint256 totalBalance = this.totalBalanceOf(token, client);

        // Calculate available surplus (yield)
        uint256 surplus = totalBalance > principal ? totalBalance - principal : 0;

        // CRITICAL: withdrawFrom is ONLY for surplus extraction
        // If you need to withdraw principal, use totalWithdrawal() with timelock protection
        require(
            amount <= surplus,
            "AutoPoolYieldStrategy: amount exceeds available surplus, use totalWithdrawal() for principal"
        );

        // Unstake ALL shares to ensure we have them available for withdrawal
        uint256 totalShares = mainRewarder.balanceOf(address(this));
        require(totalShares > 0, "AutoPoolYieldStrategy: no shares available");
        mainRewarder.withdraw(address(this), totalShares, false);

        // CRITICAL: Use redeem() instead of withdraw() to avoid ERC4626 rounding issues
        // For surplus withdrawals, convert the requested amount to shares using convertToShares()
        // This differs from withdraw() which uses proportional calculation since surplus is
        // not tracked in principal accounting
        uint256 sharesToRedeem = autoPoolVault.convertToShares(amount);
        uint256 availableShares = autoPoolVault.balanceOf(address(this));
        if (sharesToRedeem > availableShares) {
            sharesToRedeem = availableShares;
        }
        autoPoolVault.redeem(sharesToRedeem, recipient, address(this));

        // Re-stake ALL remaining vault shares (yield preservation)
        uint256 leftoverShares = autoPoolVault.balanceOf(address(this));
        if (leftoverShares > 0) {
            mainRewarder.stake(address(this), leftoverShares);
        }

        // CORRECT: NEVER modify principal tracking for surplus withdrawals
        // clientBalances[token][client] stays unchanged - principal is immutable here
        // totalDeposited[token] stays unchanged - only tracking actual deposits
        // Only the vault shares are reduced, which affects totalBalanceOf() but not principalOf()
    }
}
