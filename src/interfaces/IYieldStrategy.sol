// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IYieldStrategy
 * @notice Interface for yield strategy adapter that handles token deposits and withdrawals
 */
interface IYieldStrategy {
    /**
     * @notice Deposit tokens into the vault
     * @param token The token address to deposit
     * @param amount The amount of tokens to deposit
     * @param recipient The address that will own the deposited tokens
     * @return creditedPrincipal The principal actually booked against `recipient`
     *         (`clientBalances` / `totalDeposited`). This is the credited principal, NOT the
     *         nominal `amount` echoed in the `Deposited` event:
     *           - Direct (full-credit) strategies return `amount`.
     *           - The market strategy returns the story-043 slippage haircut
     *             (`amount * (MAX_BPS - slippageToleranceBps) / MAX_BPS`), which is < `amount`.
     *         It is NOT a mark-to-actual figure (e.g. shares received valued at the current rate);
     *         it tracks booked principal so a caller can mirror the strategy's ledger exactly.
     *         Callers may discard it; existing callers that ignore the return are unaffected.
     */
    function deposit(address token, uint256 amount, address recipient) external returns (uint256 creditedPrincipal);

    /**
     * @notice Withdraw tokens from the vault
     * @param token The token address to withdraw
     * @param amount The amount of tokens to withdraw
     * @param recipient The address that will receive the tokens
     */
    function withdraw(address token, uint256 amount, address recipient) external;

    /**
     * @notice Size a withdrawal against this strategy's exit haircut: given the net underlying a
     *         caller must end up holding, report what it has to request and what it is guaranteed.
     * @param token The token address (must be the strategy's underlying token)
     * @param account The account whose booked principal the exit would be debited from. Present
     *        because the per-account cap `min(amount, clientBalances[token][account])` lives in the
     *        base's `_withdrawInternal` and is replicated faithfully here — the quote never names a
     *        request the base would silently shrink.
     * @param netWanted The net underlying amount the caller needs to be holding after `withdraw`
     * @return grossToRequest The `amount` to pass to `withdraw` in order to end up with `netWanted`,
     *         capped to the account's available principal. Direct (full-credit) strategies return
     *         `netWanted` unchanged (subject to that cap) because their exit applies no haircut.
     *         The market strategy returns the algebraic inverse of the story-043 exit haircut,
     *         `ceil(netWanted * MAX_BPS / (MAX_BPS - slippageToleranceBps))`, which is > `netWanted`.
     *         Returning this alongside `netGuaranteed` in ONE static call is the point of the
     *         function: the share round-trip does not cleanly invert, so a consumer must never try
     *         to derive one figure from the other, call twice, or iterate.
     * @return netGuaranteed The net underlying the strategy guarantees will be delivered if exactly
     *         `grossToRequest` is withdrawn. Direct strategies return `grossToRequest`. The market
     *         strategy returns the swap's `minOut` floor for that request. When the cap binds — the
     *         account's principal, or (market) the shares the strategy actually holds — this comes
     *         back BELOW `netWanted`, which is the honest answer: the position cannot cover it.
     *
     *         ⚠️ `netGuaranteed` IS A FLOOR, NOT AN EXPECTATION, AND NOT A SETTLEMENT FIGURE. ⚠️
     *         It is the worst case the strategy will accept, not what it expects to receive.
     *         Consumers MUST size their arithmetic against it and MUST THEN MEASURE THE ACTUAL
     *         BALANCE DELTA ACROSS `withdraw` — treating this quote as the delivered amount
     *         re-introduces exactly the shortfall bug the function exists to let callers avoid.
     *         Three independent reasons, none of which can be engineered away here:
     *           1. The AMM pays anywhere AT OR ABOVE `minOut`; the real figure is only known
     *              post-trade, and `IAMMAdapter` exposes no quote view. Delivery routinely EXCEEDS
     *              the quote (see `testDepositWithFavorableAMMRate` for the deposit-side twin).
     *           2. The quote reads live vault and AMM state and is manipulable within a block.
     *           3. It is built on `convertToAssets`, the FEE-FREE ideal conversion (story 049 —
     *              `previewRedeem` is unusable because Tokemak-Autopool-style vaults mutate state
     *              inside it and trap under STATICCALL). On a vault that charges a withdrawal or
     *              exit fee the preview therefore OVER-QUOTES.
     *         This is the same "actual delivered vs snapshot/ideal" divergence documented in the
     *         repo's CLAUDE.md section `## skimSurplus return value vs. SurplusSkimmed events`,
     *         whose warning applies verbatim: for `ERC4626MarketYieldStrategy` the swap output is
     *         governed by the AMM rate, so THE GAP CAN BE LARGE IN EITHER DIRECTION.
     * @dev Read-only and STATICCALL-safe by construction. `(0, 0)` is a valid answer meaning "this
     *      strategy can guarantee nothing at all here" — an empty position, an unknown account, or
     *      (market) a 100% slippage tolerance, where no request could carry a guarantee.
     */
    function previewExitFor(address token, address account, uint256 netWanted)
        external
        view
        returns (uint256 grossToRequest, uint256 netGuaranteed);

    /// @notice Write down the caller's own recorded principal by `amount`, WITHOUT touching the
    ///         underlying vault's shares (no redeem/withdraw/transfer). Decrements both
    ///         clientBalances[token][msg.sender] and totalDeposited[token], preserving the
    ///         invariant totalDeposited == Σ clientBalances. Intended for a principal-only client
    ///         (e.g. the stable-staker) to release dormant principal so the corresponding vault value
    ///         flows to yield on recovery rather than remaining a principal claim. Over-requests are
    ///         capped to the caller's available principal. Client-gated (onlyAuthorizedClient).
    function relinquishPrincipal(address token, uint256 amount) external;

    /// @notice Owner-only override: write down a named `client`'s recorded principal by `amount`
    ///         on the underlying token, with identical semantics to relinquishPrincipal (no vault
    ///         interaction, both maps decremented, over-requests capped). Mirrors withdrawAsOwner.
    function relinquishPrincipalAsOwner(address client, uint256 amount) external;

    /**
     * @notice Get the balance of a token for a specific address
     * @param token The token address
     * @param account The account address
     * @return The token balance
     * @dev DEPRECATED: This method's semantics are ambiguous (principal vs principal+yield).
     *      Use principalOf() for principal-only queries or totalBalanceOf() for principal+yield.
     *      For backward compatibility, existing implementations should maintain current behavior,
     *      but new code should use the explicit methods instead.
     */
    function balanceOf(address token, address account) external view returns (uint256);

    /**
     * @notice Returns the principal balance for a specific address
     * @dev Principal represents the amount originally deposited, excluding any accumulated yield.
     *      This is the basis for calculating surplus yield in the SurplusTracker system.
     * @param token The token address to query
     * @param account The account address to query the principal balance for
     * @return The principal balance of the account (deposits only, no yield)
     */
    function principalOf(address token, address account) external view returns (uint256);

    /**
     * @notice Returns the total balance including accumulated yield for a specific address
     * @dev Total balance represents principal + yield. This is the amount that would be
     *      received if the account withdrew all their funds. The difference between
     *      totalBalanceOf() and principalOf() represents the accumulated yield that can
     *      be extracted via the SurplusWithdrawer system.
     * @param token The token address to query
     * @param account The account address to query the total balance for
     * @return The total balance of the account (principal + accumulated yield)
     */
    function totalBalanceOf(address token, address account) external view returns (uint256);

    /**
     * @notice Set client authorization for deposit/withdraw operations
     * @param client The address of the client contract
     * @param _auth Whether to authorize (true) or deauthorize (false) the client
     * @dev This function should be restricted to the contract owner
     */
    function setClient(address client, bool _auth) external;

    /**
     * @notice Emergency withdraw function for owner to withdraw funds
     * @param amount The amount of tokens to withdraw
     * @dev This function should be restricted to the contract owner
     */
    function emergencyWithdraw(uint256 amount) external;

    /**
     * @notice Two-phase total withdrawal function for emergency fund migration
     * @param token The token address to withdraw from
     * @param client The client address whose tokens to withdraw
     * @dev Phase 1: Initiates 24-hour waiting period. Phase 2: Executes withdrawal within 48-hour window.
     *      This provides community protection against rugpulls while allowing legitimate fund migrations.
     *      Only the contract owner can initiate this process.
     */
    function totalWithdrawal(address token, address client) external;

    /**
     * @notice Skim the full available surplus (yield) of every authorized client to one recipient
     *         in a single underlying withdrawal. Always claims all clients (fairness); the strategy
     *         owns the client set, so no client list is supplied by the caller. Principal untouched.
     * @param token The token address to skim
     * @param recipient The address that will receive all skimmed proceeds
     * @return underlyingReceived The actual underlying token amount delivered to `recipient`
     *         (the real redeem/swap result). NOTE: this can differ from the sum of the per-client
     *         `surplus` amounts emitted in `SurplusSkimmed` events — those carry the pre-redeem/
     *         pre-swap snapshot surplus in vault-asset terms, whereas this value is post-slippage /
     *         post-rounding underlying. External bookkeeping must not assume the two are equal.
     * @dev Only authorized withdrawers can call this function. Snapshot semantics: every client's
     *      surplus is read before any redemption. An empty client set is a no-op (no revert, returns 0).
     */
    function skimSurplus(address token, address recipient) external returns (uint256 underlyingReceived);

    /**
     * @notice The set of clients the strategy will skim (and that may deposit/withdraw)
     * @return The list of currently-authorized client addresses
     */
    function getAuthorizedClients() external view returns (address[] memory);

    /**
     * @notice Set a client's set-aside buffer percentage (0–100). Owner-gated. On skimSurplus this
     *         percentage of the client's realized surplus is returned to the client (a reserve against
     *         below-par dips) and the skim's delivered amount / return value is reduced accordingly.
     */
    function setSetAsideBuffer(address client, uint256 bufferPercent) external;

    /**
     * @notice The set-aside buffer percentage (0–100) currently configured for a client.
     */
    function setAsideBufferSize(address client) external view returns (uint256);

    /**
     * @notice Set the global recipient for aggregated set-aside buffers. Owner-gated.
     *         Must be non-zero. Must be configured before any skim where totalBufferShares > 0.
     * @param _recipient The address that will receive all set-aside buffer tokens on each skim.
     */
    function setSetAsideBufferRecipient(address _recipient) external;

    /**
     * @notice The current global set-aside buffer recipient address.
     *         Returns address(0) if unset (not yet configured).
     */
    function setAsideBufferRecipient() external view returns (address);
}
