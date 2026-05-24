// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../AYieldStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title ERC4626YieldStrategy
 * @notice Generic yield strategy adapter for any standard ERC4626 vault
 * @dev Extends AYieldStrategy to provide a simple adapter for ERC4626-compliant vaults.
 *      Unlike AutoPoolYieldStrategy, shares are held directly by this contract — there is
 *      no secondary staking layer (e.g., MainRewarder). This dramatically simplifies the
 *      deposit/withdraw flow to single vault calls.
 *
 *      This strategy is NOT designed for any specific token-vault combo. It works for any
 *      ERC4626-compliant vault (yBOLD, sBOLD, sUSDS, etc.) via constructor-only configuration.
 *
 *      WARNING: Rebasing vaults are NOT supported. This strategy assumes vault share prices
 *      only increase (or stay flat) over time. Rebasing vaults that change balanceOf() without
 *      transfer events will produce incorrect accounting.
 *
 *      Rounding rules: All rounding favors the protocol. Uses vault.redeem() (not withdraw())
 *      for deterministic share burning. Principal is decremented by requested amount, not
 *      received amount, so any shortfall accumulates as protocol-owned yield.
 */
contract ERC4626YieldStrategy is AYieldStrategy {
    using SafeERC20 for IERC20;

    // ============ STATE VARIABLES ============

    /// @notice The underlying token this strategy accepts (e.g., BOLD, USDS)
    IERC20 public immutable underlyingToken;

    /// @notice The external ERC4626 vault this strategy deposits into
    IERC4626 public immutable vault;

    /// @notice Tracks each client's deposited principal per token
    mapping(address => mapping(address => uint256)) private clientBalances;

    /// @notice Tracks total deposited principal across all clients per token
    mapping(address => uint256) private totalDeposited;

    // ============ EVENTS ============

    /**
     * @notice Emitted when underlying token is deposited into the ERC4626 vault
     * @param token The token address
     * @param depositor The address that initiated the deposit (client or owner)
     * @param recipient The recipient of the deposited tokens (for accounting)
     * @param amount The amount of underlying token deposited
     * @param sharesReceived The amount of vault shares received
     */
    event Deposited(
        address indexed token,
        address indexed depositor,
        address indexed recipient,
        uint256 amount,
        uint256 sharesReceived
    );

    /**
     * @notice Emitted when vault shares are redeemed for underlying token
     * @param token The token address
     * @param withdrawer The address that initiated the withdrawal
     * @param recipient The recipient of the withdrawn tokens
     * @param amount The principal amount withdrawn (requested)
     * @param sharesBurned The amount of vault shares burned
     */
    event Withdrawn(
        address indexed token,
        address indexed withdrawer,
        address indexed recipient,
        uint256 amount,
        uint256 sharesBurned
    );

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initialize the ERC4626YieldStrategy
     * @param _owner The owner of the strategy contract
     * @param _underlyingToken The underlying token address (e.g., BOLD, USDS)
     * @param _erc4626Vault The ERC4626 vault address
     */
    constructor(address _owner, address _underlyingToken, address _erc4626Vault) AYieldStrategy(_owner) {
        require(_underlyingToken != address(0), "ERC4626YieldStrategy: underlying token cannot be zero address");
        require(_erc4626Vault != address(0), "ERC4626YieldStrategy: vault cannot be zero address");

        underlyingToken = IERC20(_underlyingToken);
        vault = IERC4626(_erc4626Vault);

        // Approve vault to spend unlimited underlying tokens
        IERC20(_underlyingToken).approve(_erc4626Vault, type(uint256).max);
    }

    // ============ PUBLIC VIEW FUNCTIONS ============

    /**
     * @notice Returns the underlying token address this strategy accepts
     * @return The address of the underlying token
     */
    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    /**
     * @notice Get principal balance (amount deposited, excluding yield)
     * @param token The token address (must be underlying token)
     * @param account The account address
     * @return The principal amount deposited (excluding yield)
     */
    function principalOf(address token, address account) external view override returns (uint256) {
        require(token == address(underlyingToken), "ERC4626YieldStrategy: only underlying token supported");
        return clientBalances[token][account];
    }

    /**
     * @notice Get total balance including proportional yield
     * @param token The token address (must be underlying token)
     * @param account The account address
     * @return The total balance including principal and accumulated yield
     * @dev Calculates user's proportional share of total vault value:
     *      (totalVaultValue * userPrincipal) / totalDeposited
     */
    function totalBalanceOf(address token, address account) external view override returns (uint256) {
        require(token == address(underlyingToken), "ERC4626YieldStrategy: only underlying token supported");

        uint256 principal = clientBalances[token][account];
        if (principal == 0 || totalDeposited[token] == 0) {
            return 0;
        }

        // Calculate proportional share of total vault value
        uint256 totalShares = vault.balanceOf(address(this));
        uint256 totalValue = vault.convertToAssets(totalShares);

        // User's proportion: (userPrincipal / totalPrincipal) * totalValue
        return (totalValue * principal) / totalDeposited[token];
    }

    /**
     * @notice Get balance (returns principal for backward compatibility)
     * @param token The token address
     * @param account The account address
     * @return The principal balance
     * @dev DEPRECATED: Use principalOf() or totalBalanceOf() explicitly.
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
     * @notice Get the total vault shares held directly by this strategy
     * @return The total amount of vault shares
     */
    function getTotalShares() external view returns (uint256) {
        return vault.balanceOf(address(this));
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Deposit underlying tokens into the ERC4626 vault
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to deposit
     * @param recipient The address that will own the deposited tokens (for accounting)
     * @dev Only authorized clients can call this function.
     *      WARNING: Rebasing vaults are NOT supported.
     */
    function deposit(address token, uint256 amount, address recipient)
        external
        override
        onlyAuthorizedClient
        nonReentrant
        whenNotPaused
    {
        _depositInternal(token, amount, recipient, msg.sender);
    }

    /**
     * @notice Withdraw underlying tokens from the ERC4626 vault
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to withdraw (principal only)
     * @param recipient The address that will receive the tokens
     * @dev Only authorized clients can call this function.
     *      Uses redeem() for deterministic share burning. Rounding favors protocol.
     *      In the standard withdraw flow, the recipient is also the balance holder.
     */
    function withdraw(address token, uint256 amount, address recipient)
        external
        override
        onlyAuthorizedClient
        nonReentrant
        whenNotPaused
    {
        _withdrawInternal(token, amount, recipient, recipient);
    }

    /**
     * @notice Owner-only deposit on behalf of a client, bypassing client authorization
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to deposit
     * @param client The client address whose balance will be credited
     * @dev Does NOT have whenNotPaused — owner should be able to act in emergencies.
     *      Tokens are transferred from msg.sender (the owner).
     */
    function depositAsOwner(address token, uint256 amount, address client) external onlyOwner nonReentrant {
        _depositInternal(token, amount, client, msg.sender);
    }

    /**
     * @notice Owner-only withdrawal on behalf of a client, bypassing client authorization
     * @param client The client address whose balance will be debited
     * @param recipient The address that will receive the withdrawn tokens
     * @param amount The amount to withdraw from the client's principal
     * @dev Does NOT have whenNotPaused — owner should be able to act in emergencies.
     *      The client's balance is debited; the recipient receives the tokens.
     */
    function withdrawAsOwner(address client, address recipient, uint256 amount) external onlyOwner nonReentrant {
        _withdrawInternal(address(underlyingToken), amount, recipient, client);
    }

    // ============ INTERNAL SHARED LOGIC ============

    /**
     * @notice Internal deposit logic shared between deposit() and depositAsOwner()
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to deposit
     * @param recipient The address credited in accounting (clientBalances)
     * @param depositor The address tokens are transferred from
     */
    function _depositInternal(address token, uint256 amount, address recipient, address depositor) internal {
        require(token == address(underlyingToken), "ERC4626YieldStrategy: only underlying token supported");
        require(amount > 0, "ERC4626YieldStrategy: amount must be greater than zero");
        require(recipient != address(0), "ERC4626YieldStrategy: recipient cannot be zero address");

        // Transfer underlying token from depositor to this contract
        underlyingToken.safeTransferFrom(depositor, address(this), amount);

        // Deposit into ERC4626 vault — shares come directly to this contract
        uint256 sharesReceived = vault.deposit(amount, address(this));
        require(sharesReceived > 0, "ERC4626YieldStrategy: no shares received");

        // Update principal tracking
        clientBalances[token][recipient] += amount;
        totalDeposited[token] += amount;

        emit Deposited(token, depositor, recipient, amount, sharesReceived);
    }

    /**
     * @notice Internal withdraw logic shared between withdraw() and withdrawAsOwner()
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to withdraw
     * @param recipient The address that receives the underlying tokens
     * @param balanceHolder The address whose clientBalances are debited
     * @dev For standard withdraw(), recipient == balanceHolder.
     *      For withdrawAsOwner(), the client's balance is debited but a different recipient receives tokens.
     */
    function _withdrawInternal(address token, uint256 amount, address recipient, address balanceHolder) internal {
        require(token == address(underlyingToken), "ERC4626YieldStrategy: only underlying token supported");
        require(amount > 0, "ERC4626YieldStrategy: amount must be greater than zero");
        require(recipient != address(0), "ERC4626YieldStrategy: recipient cannot be zero address");

        // Cap amount to available principal (prevents dust from blocking withdrawal)
        uint256 availablePrincipal = clientBalances[token][balanceHolder];
        if (amount > availablePrincipal) {
            amount = availablePrincipal;
        }

        // Convert requested amount to shares, cap to actual balance
        uint256 sharesToRedeem = vault.convertToShares(amount);
        uint256 availableShares = vault.balanceOf(address(this));
        if (sharesToRedeem > availableShares) {
            sharesToRedeem = availableShares;
        }

        // Redeem shares for underlying tokens — sent directly to recipient
        vault.redeem(sharesToRedeem, recipient, address(this));

        // SECURITY: Decrement principal by REQUESTED amount, not RECEIVED amount
        // Any difference accumulates as protocol-owned yield
        clientBalances[token][balanceHolder] -= amount;
        totalDeposited[token] -= amount;

        emit Withdrawn(token, msg.sender, recipient, amount, sharesToRedeem);
    }

    // ============ INTERNAL VIRTUAL FUNCTION IMPLEMENTATIONS ============

    /**
     * @notice Internal emergency withdraw implementation
     * @param amount The amount of underlying tokens to withdraw
     * @dev Redeems vault shares and transfers underlying to owner.
     *      Works whether paused or not (emergencyWithdraw in AYieldStrategy has no whenNotPaused).
     */
    function _emergencyWithdraw(uint256 amount) internal override {
        uint256 totalShares = vault.balanceOf(address(this));
        require(totalShares > 0, "ERC4626YieldStrategy: no shares to withdraw");

        // Calculate how many shares needed for the requested amount
        uint256 totalAssets = vault.convertToAssets(totalShares);
        uint256 sharesToWithdraw = totalShares;

        if (amount < totalAssets) {
            sharesToWithdraw = vault.convertToShares(amount);
            // Cap to available shares
            if (sharesToWithdraw > totalShares) {
                sharesToWithdraw = totalShares;
            }
        }

        // Redeem from vault
        uint256 assetsReceived = vault.redeem(sharesToWithdraw, address(this), address(this));

        // Transfer to owner
        uint256 actualAmount = assetsReceived < amount ? assetsReceived : amount;
        underlyingToken.safeTransfer(owner(), actualAmount);
    }

    /**
     * @notice Internal total withdraw implementation for emergency fund migration
     * @param token The token address (must be underlying token)
     * @param client The client address whose tokens to withdraw
     * @param amount The amount to withdraw (from cached balance in two-phase flow)
     * @dev Calculates proportional shares, redeems, zeros out client, transfers to owner.
     */
    function _totalWithdraw(address token, address client, uint256 amount) internal override {
        require(token == address(underlyingToken), "ERC4626YieldStrategy: only underlying token supported");
        require(amount > 0, "ERC4626YieldStrategy: amount must be greater than zero");

        // Calculate proportional shares to withdraw
        uint256 totalShares = vault.balanceOf(address(this));
        if (totalShares == 0 || totalDeposited[token] == 0) {
            return; // Nothing to withdraw
        }

        uint256 clientStoredBalance = clientBalances[token][client];
        uint256 sharesToWithdraw = (totalShares * clientStoredBalance) / totalDeposited[token];

        if (sharesToWithdraw > 0) {
            // Redeem from vault
            uint256 assetsReceived = vault.redeem(sharesToWithdraw, address(this), address(this));

            // Update balances — zero out client
            clientBalances[token][client] = 0;
            totalDeposited[token] -= clientStoredBalance;

            // Transfer to owner (for manual redistribution)
            underlyingToken.safeTransfer(owner(), assetsReceived);
        }
    }

    /**
     * @notice Internal skimSurplus implementation for authorized surplus extraction
     * @param token The token address (must be underlying token)
     * @param client The client address whose surplus to skim
     * @param amount The amount to skim (MUST be <= available surplus)
     * @param recipient The address that will receive the skimmed tokens
     * @dev Allows authorized withdrawers to extract surplus (yield) without touching principal.
     *      CRITICAL: Principal tracking (clientBalances) is NEVER modified by this function.
     *      Only surplus/yield can be skimmed.
     */
    function _skimSurplus(address token, address client, uint256 amount, address recipient) internal override {
        require(token == address(underlyingToken), "ERC4626YieldStrategy: only underlying token supported");

        // Get current balances
        uint256 principal = clientBalances[token][client];
        uint256 totalBalance = this.totalBalanceOf(token, client);

        // Calculate available surplus (yield)
        uint256 surplus = totalBalance > principal ? totalBalance - principal : 0;

        // CRITICAL: withdrawFrom is ONLY for surplus extraction
        require(
            amount <= surplus,
            "ERC4626YieldStrategy: amount exceeds available surplus, use totalWithdrawal() for principal"
        );

        // Convert requested amount to shares, cap to available shares
        uint256 sharesToRedeem = vault.convertToShares(amount);
        uint256 availableShares = vault.balanceOf(address(this));
        if (sharesToRedeem > availableShares) {
            sharesToRedeem = availableShares;
        }
        vault.redeem(sharesToRedeem, recipient, address(this));

        // CORRECT: NEVER modify principal tracking for surplus withdrawals
        // clientBalances[token][client] stays unchanged
        // totalDeposited[token] stays unchanged
        // Only vault shares are reduced, affecting totalBalanceOf() but not principalOf()
    }

    /**
     * @notice Batch skim the full available surplus of multiple clients in a single redeem
     * @param token The token address (must be underlying token)
     * @param clients The client addresses whose full available surplus is skimmed
     * @param recipient The address that will receive all skimmed proceeds
     * @dev Snapshots total value once, sums per-client FLOORED shares (protocol-favoring rounding),
     *      and performs a SINGLE vault.redeem. Principal accounting is left untouched.
     */
    function _skimSurplusBatch(address token, address[] calldata clients, address recipient) internal override {
        require(token == address(underlyingToken), "ERC4626YieldStrategy: only underlying token supported");
        uint256 td = totalDeposited[token];
        if (td == 0) return;
        uint256 totalValue = vault.convertToAssets(vault.balanceOf(address(this))); // snapshot
        uint256 totalShares;
        for (uint256 i = 0; i < clients.length; i++) {
            address client = clients[i];
            require(client != address(0), "ERC4626YieldStrategy: client cannot be zero address");
            uint256 principal = clientBalances[token][client];
            if (principal == 0) continue;
            uint256 total = (totalValue * principal) / td; // == totalBalanceOf(client)
            uint256 surplus = total > principal ? total - principal : 0;
            if (surplus == 0) continue;
            totalShares += vault.convertToShares(surplus); // per-client floor (protocol-favoring)
            emit SurplusSkimmed(token, client, msg.sender, surplus, recipient);
        }
        if (totalShares == 0) return;
        uint256 availableShares = vault.balanceOf(address(this));
        if (totalShares > availableShares) totalShares = availableShares;
        vault.redeem(totalShares, recipient, address(this)); // SINGLE redeem
        // Principal tracking intentionally untouched (surplus-only), as in _skimSurplus.
    }
}
