// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../AYieldStrategy.sol";
import "../AMMAdapters/IAMMAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title ERC4626MarketYieldStrategy
 * @notice Yield strategy that buys/sells ERC4626 vault tokens via AMM instead of direct deposit/withdraw
 * @dev Addresses ERC4626 vaults with restrictions (e.g., sUSDe's 7-day cooldown on withdrawals)
 *      by purchasing vault tokens on the open market during deposit and selling them during withdrawal.
 *
 *      This strategy uses the same principal tracking and proportional yield distribution as
 *      ERC4626YieldStrategy, but replaces vault.deposit()/vault.redeem() with AMM swaps.
 *
 *      WARNING: Rebasing vaults are NOT supported. This strategy assumes vault share prices
 *      only increase (or stay flat) over time.
 *
 *      Rounding rules: All rounding favors the protocol. Principal is decremented by requested
 *      amount, not received amount, so any shortfall accumulates as protocol-owned yield.
 */
contract ERC4626MarketYieldStrategy is AYieldStrategy {
    using SafeERC20 for IERC20;

    // ============ STATE VARIABLES ============

    /// @notice The underlying token this strategy accepts (e.g., USDC, DAI)
    IERC20 public immutable underlyingToken;

    /// @notice The external ERC4626 vault whose shares are traded via AMM
    IERC4626 public immutable vault;

    /// @notice The AMM adapter used for swapping between underlying and vault tokens
    IAMMAdapter public immutable ammAdapter;

    /// @notice Slippage tolerance in basis points (e.g., 50 = 0.5%)
    uint256 public slippageToleranceBps;

    /// @notice Maximum basis points constant
    uint256 public constant MAX_BPS = 10000;

    /// @notice Tracks each client's deposited principal per token
    mapping(address => mapping(address => uint256)) private clientBalances;

    /// @notice Tracks total deposited principal across all clients per token
    mapping(address => uint256) private totalDeposited;

    // ============ EVENTS ============

    /**
     * @notice Emitted when underlying tokens are swapped for vault tokens via AMM
     * @param token The underlying token address
     * @param depositor The address that initiated the deposit (client or owner)
     * @param recipient The recipient of the deposited tokens (for accounting)
     * @param amount The NOMINAL amount of underlying token sent in by the depositor.
     *        NOTE: this is the gross input, NOT the principal credited. Principal is credited
     *        conservatively as the slippage-haircut value (`_creditedPrincipal(amount)` =
     *        amount * (MAX_BPS - slippageToleranceBps) / MAX_BPS); the gap between nominal and
     *        credited surfaces as protocol yield. Use `principalOf` for the recorded principal.
     * @param sharesReceived The amount of vault shares received from AMM swap
     */
    event Deposited(
        address indexed token,
        address indexed depositor,
        address indexed recipient,
        uint256 amount,
        uint256 sharesReceived
    );

    /**
     * @notice Emitted when vault tokens are swapped for underlying tokens via AMM
     * @param token The underlying token address
     * @param withdrawer The address that initiated the withdrawal
     * @param recipient The recipient of the withdrawn tokens
     * @param amount The principal amount withdrawn (requested)
     * @param sharesSold The amount of vault shares sold via AMM
     */
    event Withdrawn(
        address indexed token, address indexed withdrawer, address indexed recipient, uint256 amount, uint256 sharesSold
    );

    /**
     * @notice Emitted when slippage tolerance is updated
     * @param oldBps The previous slippage tolerance in basis points
     * @param newBps The new slippage tolerance in basis points
     */
    event SlippageToleranceSet(uint256 oldBps, uint256 newBps);

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initialize the ERC4626MarketYieldStrategy
     * @param _owner The owner of the strategy contract
     * @param _underlyingToken The underlying token address (e.g., USDC, DAI)
     * @param _erc4626Vault The ERC4626 vault address whose shares are traded
     * @param _ammAdapter The AMM adapter address for swapping tokens
     */
    constructor(address _owner, address _underlyingToken, address _erc4626Vault, address _ammAdapter)
        AYieldStrategy(_owner)
    {
        require(_underlyingToken != address(0), "ERC4626MarketYieldStrategy: underlying token cannot be zero address");
        require(_erc4626Vault != address(0), "ERC4626MarketYieldStrategy: vault cannot be zero address");
        require(_ammAdapter != address(0), "ERC4626MarketYieldStrategy: AMM adapter cannot be zero address");

        underlyingToken = IERC20(_underlyingToken);
        vault = IERC4626(_erc4626Vault);
        ammAdapter = IAMMAdapter(_ammAdapter);
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
        require(token == address(underlyingToken), "ERC4626MarketYieldStrategy: only underlying token supported");
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
        require(token == address(underlyingToken), "ERC4626MarketYieldStrategy: only underlying token supported");

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

    // ============ OWNER CONFIGURATION ============

    /**
     * @notice Set the slippage tolerance for AMM swaps
     * @param _bps The slippage tolerance in basis points (e.g., 50 = 0.5%)
     * @dev Only the contract owner can call this function
     */
    function setSlippageTolerance(uint256 _bps) external onlyOwner {
        require(_bps <= MAX_BPS, "ERC4626MarketYieldStrategy: slippage tolerance exceeds MAX_BPS");
        uint256 oldBps = slippageToleranceBps;
        slippageToleranceBps = _bps;
        emit SlippageToleranceSet(oldBps, _bps);
    }

    // ============ INTERNAL HELPERS ============

    /**
     * @notice Conservative principal credited for a nominal deposit `amount`.
     * @param amount The nominal underlying amount sent by the depositor
     * @return The slippage-haircut principal: amount * (MAX_BPS - slippageToleranceBps) / MAX_BPS
     * @dev This is the worst-case fair value of the position the swap can return at the current
     *      tolerance. The deposit's `minOut` is derived from this SAME value (via convertToShares),
     *      so the credited principal and the swap floor can never drift apart — which is what makes
     *      `fairValueOfShares >= creditedPrincipal` a provable solvency invariant.
     */
    function _creditedPrincipal(uint256 amount) internal view returns (uint256) {
        return amount * (MAX_BPS - slippageToleranceBps) / MAX_BPS;
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @notice Deposit underlying tokens by swapping for vault tokens via AMM
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to deposit
     * @param recipient The address that will own the deposited tokens (for accounting)
     * @dev Only authorized clients can call this function.
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
     * @notice Withdraw underlying tokens by selling vault tokens via AMM
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to withdraw (principal only)
     * @param recipient The address that will receive the tokens
     * @dev Only authorized clients can call this function.
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
     * @dev Does NOT have whenNotPaused -- owner should be able to act in emergencies.
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
     * @dev Does NOT have whenNotPaused -- owner should be able to act in emergencies.
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
        require(token == address(underlyingToken), "ERC4626MarketYieldStrategy: only underlying token supported");
        require(amount > 0, "ERC4626MarketYieldStrategy: amount must be greater than zero");
        require(recipient != address(0), "ERC4626MarketYieldStrategy: recipient cannot be zero address");

        // Transfer underlying token from depositor to this contract
        underlyingToken.safeTransferFrom(depositor, address(this), amount);

        // Conservative principal: credit the worst-case fair value of the position acquired, NOT the
        // nominal amount. Tied to the same slippage bound the swap's minOut enforces, so fair value of
        // shares received >= creditedPrincipal always. The gap between worst-case and actual execution
        // surfaces as protocol yield.
        uint256 creditedPrincipal = _creditedPrincipal(amount);

        // Minimum acceptable swap output derived from the SAME haircut value, so the credit and the
        // swap floor cannot drift apart (provable solvency invariant).
        uint256 minOut = vault.convertToShares(creditedPrincipal);

        // Approve AMM adapter to spend underlying tokens
        underlyingToken.safeIncreaseAllowance(address(ammAdapter), amount);

        // Swap underlying -> vault tokens via AMM
        uint256 sharesReceived = ammAdapter.swap(address(underlyingToken), address(vault), amount, minOut);
        require(sharesReceived > 0, "ERC4626MarketYieldStrategy: no shares received");

        // Update principal tracking with the conservative (haircut) credit, NOT the nominal amount.
        clientBalances[token][recipient] += creditedPrincipal;
        totalDeposited[token] += creditedPrincipal;

        // Event emits the NOMINAL amount (gross input); credited principal is the haircut — see NatSpec.
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
        require(token == address(underlyingToken), "ERC4626MarketYieldStrategy: only underlying token supported");
        require(amount > 0, "ERC4626MarketYieldStrategy: amount must be greater than zero");
        require(recipient != address(0), "ERC4626MarketYieldStrategy: recipient cannot be zero address");

        // Cap amount to available principal (prevents dust from blocking withdrawal)
        uint256 availablePrincipal = clientBalances[token][balanceHolder];
        if (amount > availablePrincipal) {
            amount = availablePrincipal;
        }

        // Convert requested amount to shares, cap to actual balance
        uint256 sharesToSell = vault.convertToShares(amount);
        uint256 availableShares = vault.balanceOf(address(this));
        if (sharesToSell > availableShares) {
            sharesToSell = availableShares;
        }

        // Calculate ideal underlying output and minimum acceptable
        uint256 idealUnderlying = vault.convertToAssets(sharesToSell);
        uint256 minOut = idealUnderlying * (MAX_BPS - slippageToleranceBps) / MAX_BPS;

        // Approve AMM adapter to spend vault tokens
        IERC20(address(vault)).safeIncreaseAllowance(address(ammAdapter), sharesToSell);

        // Swap vault tokens -> underlying via AMM
        uint256 underlyingReceived = ammAdapter.swap(address(vault), address(underlyingToken), sharesToSell, minOut);

        // Transfer underlying to recipient
        underlyingToken.safeTransfer(recipient, underlyingReceived);

        // SECURITY: Decrement principal by REQUESTED amount, not RECEIVED amount
        // Any difference accumulates as protocol-owned yield
        clientBalances[token][balanceHolder] -= amount;
        totalDeposited[token] -= amount;

        emit Withdrawn(token, msg.sender, recipient, amount, sharesToSell);
    }

    // ============ INTERNAL VIRTUAL FUNCTION IMPLEMENTATIONS ============

    /**
     * @notice Internal emergency withdraw implementation
     * @param amount The amount of vault shares to withdraw
     * @dev Transfers vault tokens (share tokens) directly to owner since the vault may have
     *      restrictions that prevent direct redeem. Falls back to direct redeem if transfer
     *      of raw vault tokens is not desired.
     */
    function _emergencyWithdraw(uint256 amount) internal override {
        uint256 totalShares = vault.balanceOf(address(this));
        require(totalShares > 0, "ERC4626MarketYieldStrategy: no shares to withdraw");

        uint256 sharesToTransfer = amount < totalShares ? amount : totalShares;

        // Transfer vault tokens (shares) directly to owner
        // This avoids vault withdrawal restrictions (e.g., cooldown periods)
        IERC20(address(vault)).safeTransfer(owner(), sharesToTransfer);
    }

    /**
     * @notice Internal total withdraw implementation for emergency fund migration
     * @param token The token address (must be underlying token)
     * @param client The client address whose tokens to withdraw
     * @param amount The amount to withdraw (from cached balance in two-phase flow)
     * @dev Calculates proportional shares, swaps via AMM, zeros out client, transfers to owner.
     */
    function _totalWithdraw(address token, address client, uint256 amount) internal override {
        require(token == address(underlyingToken), "ERC4626MarketYieldStrategy: only underlying token supported");
        require(amount > 0, "ERC4626MarketYieldStrategy: amount must be greater than zero");

        // Calculate proportional shares to withdraw
        uint256 totalShares = vault.balanceOf(address(this));
        if (totalShares == 0 || totalDeposited[token] == 0) {
            return; // Nothing to withdraw
        }

        uint256 clientStoredBalance = clientBalances[token][client];
        uint256 sharesToSell = (totalShares * clientStoredBalance) / totalDeposited[token];

        if (sharesToSell > 0) {
            // Calculate minimum output with slippage tolerance
            uint256 idealUnderlying = vault.convertToAssets(sharesToSell);
            uint256 minOut = idealUnderlying * (MAX_BPS - slippageToleranceBps) / MAX_BPS;

            // Approve AMM adapter to spend vault tokens
            IERC20(address(vault)).safeIncreaseAllowance(address(ammAdapter), sharesToSell);

            // Swap vault tokens -> underlying via AMM
            uint256 underlyingReceived = ammAdapter.swap(address(vault), address(underlyingToken), sharesToSell, minOut);

            // Update balances -- zero out client
            clientBalances[token][client] = 0;
            totalDeposited[token] -= clientStoredBalance;

            // Transfer to owner (for manual redistribution)
            underlyingToken.safeTransfer(owner(), underlyingReceived);
        }
    }

    /**
     * @notice Skim the full available surplus of every authorized client in a SINGLE AMM swap
     * @param token The token address (must be underlying token)
     * @param clients The client addresses (the strategy's authorized set) whose surplus is skimmed
     * @param recipient The address that will receive all skimmed proceeds
     * @dev Snapshots total value once, sums per-client FLOORED shares (protocol-favoring rounding),
     *      and performs a SINGLE ammAdapter.swap with minOut computed on the aggregate.
     *      Principal accounting is left untouched. The aggregate-surplus require (audit M-01
     *      mitigation) replaces the old silent clamp: it fails LOUDLY rather than over-selling.
     *      The EnumerableSet of clients already guarantees distinctness, so this require is
     *      defense-in-depth.
     */
    function _skimSurplus(address token, address[] memory clients, address recipient)
        internal
        override
        returns (uint256 underlyingReceived)
    {
        require(token == address(underlyingToken), "ERC4626MarketYieldStrategy: only underlying token supported");
        uint256 td = totalDeposited[token];
        if (td == 0) return 0;
        uint256 totalValue = vault.convertToAssets(vault.balanceOf(address(this))); // snapshot
        uint256[] memory bufferShares = new uint256[](clients.length);
        (uint256 totalShares, uint256 totalBufferShares) =
            _accrueSurplusShares(token, clients, recipient, totalValue, bufferShares);
        if (totalShares == 0) return 0;
        // Loud aggregate-surplus ceiling (audit M-01): never sell beyond the protocol's surplus.
        uint256 aggregateSurplus = totalValue > td ? totalValue - td : 0;
        require(
            totalShares <= vault.convertToShares(aggregateSurplus),
            "ERC4626MarketYieldStrategy: skim exceeds aggregate surplus"
        );
        // minOut is computed on the full `totalShares`: the whole surplus is sold in ONE swap; only the
        // distribution of the proceeds changes when buffers are set, so slippage behavior is unchanged.
        uint256 idealUnderlying = vault.convertToAssets(totalShares);
        uint256 minOut = idealUnderlying * (MAX_BPS - slippageToleranceBps) / MAX_BPS;
        IERC20(address(vault)).safeIncreaseAllowance(address(ammAdapter), totalShares);
        // SINGLE swap — output lands in address(this). Return value is the ACTUAL underlying received,
        // net of AMM price/slippage, and so will generally differ from the SurplusSkimmed snapshot sum
        // (vault-asset terms) — see CLAUDE.md.
        underlyingReceived = ammAdapter.swap(address(vault), address(underlyingToken), totalShares, minOut);

        // FAST PATH — no buffers configured (the default): forward the whole swap output to `recipient`.
        if (totalBufferShares == 0) {
            underlyingToken.safeTransfer(recipient, underlyingReceived);
            return underlyingReceived;
        }

        // BUFFERED PATH — split the actual proceeds: each client gets its proportional share of the
        // set-aside, the remainder goes to `recipient`. Principal tracking intentionally untouched.
        return _distributeBuffer(clients, bufferShares, underlyingReceived, totalShares, recipient);
    }

    /**
     * @notice Snapshot-loop helper: sum per-client FLOORED surplus shares and per-client buffer shares,
     *         emitting one SurplusSkimmed per surplus-bearing client.
     * @param token The underlying token
     * @param clients The client set
     * @param recipient The skim recipient (for the event)
     * @param totalValue The snapshot total vault value
     * @param bufferShares Out-param array (parallel to clients) populated with per-client buffer shares
     * @return totalShares Aggregate FLOORED surplus shares across all clients
     * @return totalBufferShares Aggregate buffer shares across all clients
     * @dev Factored out to keep `_skimSurplus` within the EVM stack-depth limit.
     */
    function _accrueSurplusShares(
        address token,
        address[] memory clients,
        address recipient,
        uint256 totalValue,
        uint256[] memory bufferShares
    ) private returns (uint256 totalShares, uint256 totalBufferShares) {
        uint256 td = totalDeposited[token];
        for (uint256 i = 0; i < clients.length; i++) {
            address client = clients[i];
            require(client != address(0), "ERC4626MarketYieldStrategy: client cannot be zero address");
            uint256 surplus;
            {
                uint256 principal = clientBalances[token][client];
                if (principal == 0) continue;
                uint256 total = (totalValue * principal) / td; // == totalBalanceOf(client)
                if (total <= principal) continue;
                surplus = total - principal;
            }
            emit SurplusSkimmed(token, client, msg.sender, surplus, recipient);
            uint256 shares = vault.convertToShares(surplus); // per-client floor (protocol-favoring)
            totalShares += shares;
            shares = shares * setAsideBufferSize[client] / 100; // reuse slot: now buffer shares (0–100)
            bufferShares[i] = shares;
            totalBufferShares += shares;
        }
    }

    /**
     * @notice Distribute actual swap proceeds: set-aside buffers to clients, remainder to recipient.
     * @param clients The client set (parallel to bufferShares)
     * @param bufferShares Per-client buffer shares (indexed by loop position)
     * @param underlyingReceived The actual underlying received from the single swap
     * @param totalShares The aggregate shares sold in the swap
     * @param recipient The address that receives the remainder
     * @return toRecipient The amount delivered to `recipient` (reduced by total set-aside)
     * @dev Factored out to keep the caller within the EVM stack-depth limit.
     */
    function _distributeBuffer(
        address[] memory clients,
        uint256[] memory bufferShares,
        uint256 underlyingReceived,
        uint256 totalShares,
        address recipient
    ) private returns (uint256 toRecipient) {
        uint256 totalSetAside;
        for (uint256 i = 0; i < clients.length; i++) {
            if (bufferShares[i] == 0) continue;
            uint256 buf = underlyingReceived * bufferShares[i] / totalShares; // actual-tokens, proportional
            if (buf == 0) continue;
            totalSetAside += buf;
            underlyingToken.safeTransfer(clients[i], buf); // set aside back to the client
        }
        toRecipient = underlyingReceived - totalSetAside; // dust (rounding) favors recipient
        if (toRecipient > 0) underlyingToken.safeTransfer(recipient, toRecipient);
        return toRecipient; // RETURN VALUE REDUCED by totalSetAside
    }
}
