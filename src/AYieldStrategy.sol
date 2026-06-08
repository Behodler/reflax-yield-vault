// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IYieldStrategy.sol";
import "pauser/interfaces/IPausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title AYieldStrategy
 * @notice Abstract yield strategy contract with security features and access control
 * @dev Provides base implementation for yield strategy adapters with owner and multiple client access control.
 *      Implements IPausable for integration with the Global Pauser contract.
 */
abstract contract AYieldStrategy is IYieldStrategy, IPausable, Ownable, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============ STATE VARIABLES ============

    /// @notice The authorized pauser address that can pause this contract
    address private _pauser;

    /// @notice Set of addresses authorized to deposit/withdraw AND skimmed by skimSurplus.
    ///         An EnumerableSet gives O(1) membership (like the old mapping) plus enumeration,
    ///         and guarantees distinctness so skimSurplus can never over-skim (audit M-01).
    EnumerableSet.AddressSet private _authorizedClients;

    /// @notice Mapping of addresses authorized to withdraw on behalf of clients
    mapping(address => bool) public authorizedWithdrawers;

    /// @notice The underlying token this strategy accepts (e.g., BOLD, USDS, USDC)
    /// @dev Hoisted here (with `vault`) because the principal accounting below is fundamental to every
    ///      ERC4626-backed yield strategy and must live in exactly one place. Concrete strategies differ
    ///      only in HOW shares are acquired/disposed (direct redeem vs AMM swap) — the `_depositInternal`
    ///      / `_withdrawInternal` / `_skimSurplus` hooks — not in the accounting.
    IERC20 public immutable underlyingToken;

    /// @notice The external ERC4626 vault whose shares back client principal
    IERC4626 public immutable vault;

    /// @notice Tracks each client's deposited (recorded) principal per token
    mapping(address => mapping(address => uint256)) internal clientBalances;

    /// @notice Tracks total deposited principal across all clients per token
    /// @dev Invariant: totalDeposited[token] == Σ clientBalances[token][*]
    mapping(address => uint256) internal totalDeposited;

    /// @notice Per-client set-aside buffer, in PERCENT (0–100). On skimSurplus, this percentage of the
    ///         client's own realized surplus is returned to the client instead of going to `recipient`,
    ///         giving the client a reserve to absorb below-par dips. Defaults to 0 (no set-aside).
    /// @dev Keyed by `client` only (not `token`) because each concrete strategy serves a single
    ///      `underlyingToken`. A future multi-token strategy would promote this to
    ///      mapping(token => mapping(client => uint256)).
    mapping(address => uint256) public setAsideBufferSize;

    /// @notice Withdrawal status enumeration
    enum WithdrawalStatus {
        None, // No withdrawal initiated
        Initiated, // Withdrawal initiated, in 24-hour waiting period
        Executable, // Past waiting period, within 48-hour execution window
        Expired // Past execution window, state reset needed
    }

    /// @notice Structure to track withdrawal state per token/client combination
    struct WithdrawalState {
        uint256 initiatedAt; // Timestamp when withdrawal was initiated
        WithdrawalStatus status; // Current status of the withdrawal
        uint256 balance; // Cached balance at initiation time
    }

    /// @notice Mapping to track withdrawal states: token => client => WithdrawalState
    mapping(address => mapping(address => WithdrawalState)) public withdrawalStates;

    /// @notice Time constants for withdrawal phases
    uint256 public constant WAITING_PERIOD = 24 hours; // Phase 1 duration
    uint256 public constant EXECUTION_WINDOW = 48 hours; // Phase 2 duration
    uint256 public constant TOTAL_DURATION = WAITING_PERIOD + EXECUTION_WINDOW; // 72 hours total

    // ============ EVENTS ============

    /**
     * @notice Emitted when client authorization is updated
     * @param client The client address whose authorization was changed
     * @param authorized Whether the client is now authorized (true) or not (false)
     */
    event ClientAuthorizationSet(address indexed client, bool authorized);

    /**
     * @notice Emitted when withdrawer authorization is updated
     * @param withdrawer The withdrawer address whose authorization was changed
     * @param authorized Whether the withdrawer is now authorized (true) or not (false)
     */
    event WithdrawerAuthorizationSet(address indexed withdrawer, bool authorized);

    /**
     * @notice Emitted when a client's set-aside buffer percentage is updated
     * @param client The client address whose buffer was changed
     * @param oldPercent The previous buffer percentage (0–100)
     * @param newPercent The new buffer percentage (0–100)
     */
    event SetAsideBufferSet(address indexed client, uint256 oldPercent, uint256 newPercent);

    /**
     * @notice Emitted when an authorized withdrawer skims surplus from a client balance
     * @param token The token address that was skimmed
     * @param client The client address whose surplus was skimmed
     * @param withdrawer The withdrawer address that performed the skim
     * @param amount The surplus amount that was skimmed
     * @param recipient The address that received the skimmed tokens
     */
    event SurplusSkimmed(
        address indexed token, address indexed client, address indexed withdrawer, uint256 amount, address recipient
    );

    /**
     * @notice Emitted when a client's recorded principal is written down without redeeming shares
     *         (via client-initiated relinquishPrincipal or owner-initiated relinquishPrincipalAsOwner).
     * @param token The underlying token.
     * @param client The client whose principal was written down.
     * @param amount The principal amount written down.
     * @param newPrincipal The client's remaining recorded principal after the write-down.
     */
    event PrincipalRelinquished(address indexed token, address indexed client, uint256 amount, uint256 newPrincipal);

    /**
     * @notice Emitted when an emergency withdrawal is performed
     * @param owner The owner who performed the withdrawal
     * @param amount The amount withdrawn
     */
    event EmergencyWithdraw(address indexed owner, uint256 amount);

    /**
     * @notice Emitted when the pauser address is updated
     * @param oldPauser The previous pauser address
     * @param newPauser The new pauser address
     */
    event PauserSet(address indexed oldPauser, address indexed newPauser);

    /**
     * @notice Emitted when a total withdrawal is initiated (Phase 1)
     * @param token The token address for which withdrawal was initiated
     * @param client The client address whose tokens will be withdrawn
     * @param balance The balance amount that will be withdrawn in Phase 2
     * @param initiatedAt The timestamp when the withdrawal was initiated
     * @param executableAt The timestamp when Phase 2 becomes available
     */
    event WithdrawalInitiated(
        address indexed token, address indexed client, uint256 balance, uint256 initiatedAt, uint256 executableAt
    );

    /**
     * @notice Emitted when a total withdrawal is executed (Phase 2)
     * @param token The token address that was withdrawn
     * @param client The client address whose tokens were withdrawn
     * @param amount The amount that was withdrawn
     * @param executedAt The timestamp when the withdrawal was executed
     */
    event WithdrawalExecuted(address indexed token, address indexed client, uint256 amount, uint256 executedAt);

    // ============ MODIFIERS ============

    /**
     * @notice Restricts access to only authorized client contracts
     * @dev Reverts if the caller is not an authorized client address
     */
    modifier onlyAuthorizedClient() {
        require(_authorizedClients.contains(msg.sender), "AYieldStrategy: unauthorized, only authorized clients");
        _;
    }

    /**
     * @notice Restricts access to only authorized withdrawer addresses
     * @dev Reverts if the caller is not an authorized withdrawer
     */
    modifier onlyAuthorizedWithdrawer() {
        require(authorizedWithdrawers[msg.sender], "AYieldStrategy: unauthorized, only authorized withdrawers");
        _;
    }

    /**
     * @notice Restricts access to only the authorized pauser address
     * @dev Reverts if the caller is not the pauser
     */
    modifier onlyPauser() {
        require(msg.sender == _pauser, "AYieldStrategy: caller is not the pauser");
        _;
    }

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initialize the strategy with its owner, underlying token, and backing ERC4626 vault
     * @param _owner The initial owner of the contract
     * @param _underlyingToken The underlying token this strategy accepts
     * @param _erc4626Vault The ERC4626 vault whose shares back client principal
     */
    constructor(address _owner, address _underlyingToken, address _erc4626Vault) Ownable(_owner) {
        require(_owner != address(0), "AYieldStrategy: owner cannot be zero address");
        require(_underlyingToken != address(0), "AYieldStrategy: underlying token cannot be zero address");
        require(_erc4626Vault != address(0), "AYieldStrategy: vault cannot be zero address");

        underlyingToken = IERC20(_underlyingToken);
        vault = IERC4626(_erc4626Vault);
    }

    // ============ OWNER FUNCTIONS ============

    /**
     * @notice Set client authorization for deposit/withdraw operations
     * @param client The address of the client contract
     * @param _auth Whether to authorize (true) or deauthorize (false) the client
     * @dev Only the contract owner can call this function
     */
    function setClient(address client, bool _auth) external override onlyOwner {
        require(client != address(0), "AYieldStrategy: client cannot be zero address");

        if (_auth) {
            _authorizedClients.add(client); // idempotent — no duplicates possible
        } else {
            _authorizedClients.remove(client);
        }

        emit ClientAuthorizationSet(client, _auth);
    }

    /**
     * @notice Backward-compatible client-authorization membership getter
     * @param client The client address to check
     * @return True if the client is currently authorized
     * @dev Preserves the ABI shape of the former `mapping(address => bool) public authorizedClients`.
     */
    function authorizedClients(address client) external view returns (bool) {
        return _authorizedClients.contains(client);
    }

    /**
     * @notice Enumerate all currently-authorized clients (the skim target set)
     * @return The list of authorized client addresses
     */
    function getAuthorizedClients() external view override returns (address[] memory) {
        return _authorizedClients.values();
    }

    /**
     * @notice The number of currently-authorized clients
     * @return The size of the authorized-client set
     */
    function authorizedClientCount() external view returns (uint256) {
        return _authorizedClients.length();
    }

    /**
     * @notice Set withdrawer authorization for surplus withdrawal operations
     * @param withdrawer The address of the withdrawer
     * @param _auth Whether to authorize (true) or deauthorize (false) the withdrawer
     * @dev Only the contract owner can call this function
     */
    function setWithdrawer(address withdrawer, bool _auth) external onlyOwner {
        require(withdrawer != address(0), "AYieldStrategy: withdrawer cannot be zero address");

        authorizedWithdrawers[withdrawer] = _auth;

        emit WithdrawerAuthorizationSet(withdrawer, _auth);
    }

    /**
     * @notice Set a client's set-aside buffer percentage (0–100).
     * @param client The client whose buffer percentage is being set
     * @param bufferPercent The percentage (0–100) of the client's surplus retained by the client on each skim
     * @dev Owner-gated. Percentage of the client's surplus retained by the client on each skim.
     *
     *      AUDITOR NOTE — known, accepted economic quirk (NOT an exploitable vulnerability):
     *      Because each client's surplus is its principal-weighted share of the strategy's total
     *      surplus, a client that front-runs a skim with a large fresh deposit increases its share
     *      of the (fixed) total surplus and therefore the amount set aside to itself — effectively
     *      redirecting buffer that would otherwise have been attributed to other clients. This is
     *      acceptable here for two reasons: (1) every client is a protocol-owned contract, so no
     *      external attacker can profit; the funds merely move between the protocol's own buffers.
     *      (2) The buffer only makes that client's stakers better-insulated against a below-par dip —
     *      it never lets stakers withdraw MORE than their staked principal, and principal accounting
     *      is untouched by skims. The skim caller simply receives correspondingly less, which it
     *      already tolerates via its slippage floor (e.g. SYA's minRewardTokenSupplied).
     */
    function setSetAsideBuffer(address client, uint256 bufferPercent) external override onlyOwner {
        require(client != address(0), "AYieldStrategy: client cannot be zero address");
        require(bufferPercent <= 100, "AYieldStrategy: buffer percent exceeds 100");
        uint256 old = setAsideBufferSize[client];
        setAsideBufferSize[client] = bufferPercent;
        emit SetAsideBufferSet(client, old, bufferPercent);
    }

    /**
     * @notice Set the authorized pauser address
     * @param newPauser The new pauser address
     * @dev Only the contract owner can call this function
     */
    function setPauser(address newPauser) external onlyOwner {
        address oldPauser = _pauser;
        _pauser = newPauser;

        emit PauserSet(oldPauser, newPauser);
    }

    /**
     * @notice Get the authorized pauser address
     * @return The address authorized to pause/unpause this contract
     * @dev Implements IPausable.pauser()
     */
    function pauser() external view override returns (address) {
        return _pauser;
    }

    /**
     * @notice Pause the contract
     * @dev Only callable by the authorized pauser. Implements IPausable.pause()
     */
    function pause() external override onlyPauser {
        _pause();
    }

    /**
     * @notice Unpause the contract
     * @dev Callable by the owner or the pauser (Behodler3 pattern). Implements IPausable.unpause()
     */
    function unpause() external override {
        require(msg.sender == owner() || msg.sender == _pauser, "AYieldStrategy: caller is not the owner or pauser");
        _unpause();
    }

    /**
     * @notice Emergency withdraw function for owner to withdraw funds
     * @param amount The amount of tokens to withdraw
     * @dev Only the contract owner can call this function. Delegates to internal _emergencyWithdraw
     */
    function emergencyWithdraw(uint256 amount) external override onlyOwner {
        require(amount > 0, "AYieldStrategy: amount must be greater than zero");

        _emergencyWithdraw(amount);

        emit EmergencyWithdraw(msg.sender, amount);
    }

    /**
     * @notice Two-phase total withdrawal function for emergency fund migration
     * @param token The token address to withdraw from
     * @param client The client address whose tokens to withdraw
     * @dev Phase 1: Initiates 24-hour waiting period. Phase 2: Executes withdrawal within 48-hour window.
     *      Provides community protection against rugpulls while allowing legitimate fund migrations.
     */
    function totalWithdrawal(address token, address client) external override onlyOwner nonReentrant whenNotPaused {
        require(token != address(0), "AYieldStrategy: token cannot be zero address");
        require(client != address(0), "AYieldStrategy: client cannot be zero address");

        WithdrawalState storage state = withdrawalStates[token][client];
        uint256 currentTime = block.timestamp;

        // Update status based on time progression
        _updateWithdrawalStatus(state, currentTime);

        if (state.status == WithdrawalStatus.None || state.status == WithdrawalStatus.Expired) {
            // Phase 1: Initiate withdrawal
            _initiateWithdrawal(token, client, state, currentTime);
        } else if (state.status == WithdrawalStatus.Executable) {
            // Phase 2: Execute withdrawal
            _executeWithdrawal(token, client, state, currentTime);
        } else if (state.status == WithdrawalStatus.Initiated) {
            // Still in waiting period
            uint256 executableAt = state.initiatedAt + WAITING_PERIOD;
            revert(
                string(
                    abi.encodePacked(
                        "AYieldStrategy: withdrawal still in waiting period, executable at timestamp: ",
                        _uint256ToString(executableAt)
                    )
                )
            );
        }
    }

    /**
     * @notice Skim the FULL available surplus of EVERY currently-authorized client to one recipient,
     *         in a single underlying redeem/swap. Always all-or-nothing (fairness).
     * @param token The token address to skim
     * @param recipient The address that will receive all skimmed proceeds
     * @return underlyingReceived The actual underlying token amount delivered to `recipient`
     *         (the real redeem/swap result), so callers can bubble it up without re-deriving it.
     *         This can differ from the sum of the per-client `surplus` amounts emitted in
     *         `SurplusSkimmed` events (snapshot surplus, vault-asset terms) due to slippage/rounding.
     * @dev Only authorized withdrawers can call this function. The strategy owns the client set, so
     *      no client list is supplied by the caller — this structurally closes the duplicate-driven
     *      over-skim vector (audit M-01). Snapshot semantics; principal accounting untouched.
     *      An empty client set is a no-op (no revert, returns 0) so keepers/schedulers never fail spuriously.
     */
    function skimSurplus(address token, address recipient)
        external
        onlyAuthorizedWithdrawer
        nonReentrant
        whenNotPaused
        returns (uint256 underlyingReceived)
    {
        require(token != address(0), "AYieldStrategy: token cannot be zero address");
        require(recipient != address(0), "AYieldStrategy: recipient cannot be zero address");
        return _skimSurplus(token, _authorizedClients.values(), recipient);
    }

    // ============ VIRTUAL FUNCTIONS ============

    /**
     * @notice Internal emergency withdraw implementation to be overridden by concrete contracts
     * @param amount The amount of tokens to withdraw
     * @dev Must be implemented by concrete vault contracts to define emergency withdrawal logic
     */
    function _emergencyWithdraw(uint256 amount) internal virtual;

    /**
     * @notice Internal total withdraw implementation to be overridden by concrete contracts
     * @param token The token address to withdraw
     * @param client The client address whose tokens to withdraw
     * @param amount The amount to withdraw
     * @dev Must be implemented by concrete vault contracts to define total withdrawal logic
     */
    function _totalWithdraw(address token, address client, uint256 amount) internal virtual;

    /**
     * @notice Internal skimSurplus implementation to be overridden by concrete contracts
     * @param token The token address to skim
     * @param clients The client addresses (the strategy's authorized set) whose full available
     *        surplus is skimmed
     * @param recipient The address that will receive all skimmed proceeds
     * @return underlyingReceived The actual underlying delivered to `recipient` (0 on no-op paths).
     * @dev Abstract: each concrete strategy collapses the client set into a SINGLE redeem/swap.
     *      Snapshots total value once, sums per-client floored shares (protocol-favoring rounding),
     *      leaves principal untouched, and emits one SurplusSkimmed per surplus-bearing client.
     */
    function _skimSurplus(address token, address[] memory clients, address recipient)
        internal
        virtual
        returns (uint256 underlyingReceived);

    // ============ PRINCIPAL ACCOUNTING — VIEWS ============

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
        require(token == address(underlyingToken), "AYieldStrategy: only underlying token supported");
        return clientBalances[token][account];
    }

    /**
     * @notice Get total balance including proportional yield
     * @param token The token address (must be underlying token)
     * @param account The account address
     * @return The total balance including principal and accumulated yield
     * @dev Calculates the account's proportional share of total vault value:
     *      (totalVaultValue * userPrincipal) / totalDeposited
     */
    function totalBalanceOf(address token, address account) external view override returns (uint256) {
        require(token == address(underlyingToken), "AYieldStrategy: only underlying token supported");

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

    // ============ PRINCIPAL ACCOUNTING — MUTATING ENTRY POINTS ============

    /**
     * @notice Deposit underlying tokens, acquiring backing shares via the concrete strategy's hook
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to deposit
     * @param recipient The address that will own the deposited tokens (for accounting)
     * @return creditedPrincipal The principal booked against `recipient` (see IYieldStrategy.deposit)
     * @dev Only authorized clients. Share acquisition is delegated to `_depositInternal`.
     */
    function deposit(address token, uint256 amount, address recipient)
        external
        override
        onlyAuthorizedClient
        nonReentrant
        whenNotPaused
        returns (uint256 creditedPrincipal)
    {
        return _depositInternal(token, amount, recipient, msg.sender);
    }

    /**
     * @notice Withdraw underlying tokens, disposing backing shares via the concrete strategy's hook
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to withdraw (principal only)
     * @param recipient The address that will receive the tokens
     * @dev Only authorized clients. In the standard withdraw flow the recipient is also the balance holder.
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
    function depositAsOwner(address token, uint256 amount, address client)
        external
        onlyOwner
        nonReentrant
        returns (uint256 creditedPrincipal)
    {
        return _depositInternal(token, amount, client, msg.sender);
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

    /// @inheritdoc IYieldStrategy
    function relinquishPrincipal(address token, uint256 amount) external override onlyAuthorizedClient nonReentrant {
        _relinquishInternal(token, msg.sender, amount);
    }

    /// @inheritdoc IYieldStrategy
    function relinquishPrincipalAsOwner(address client, uint256 amount) external override onlyOwner nonReentrant {
        _relinquishInternal(address(underlyingToken), client, amount);
    }

    /**
     * @notice Shared write-down logic for relinquishPrincipal() and relinquishPrincipalAsOwner().
     * @param token The token address (must be underlying token)
     * @param balanceHolder The address whose recorded principal is written down.
     * @param amount The principal amount to write down (capped to the holder's available principal).
     * @dev Operates purely on recorded principal; agnostic to how that principal was credited.
     *      Decrements BOTH clientBalances and totalDeposited by the same (capped) amount and touches
     *      vault shares in NO way — no deposit/redeem/withdraw/swap/transfer.
     */
    function _relinquishInternal(address token, address balanceHolder, uint256 amount) internal {
        require(token == address(underlyingToken), "AYieldStrategy: only underlying token supported");
        require(amount > 0, "AYieldStrategy: amount must be greater than zero");

        // Cap to the holder's available principal (mirrors withdraw; protocol-favouring).
        uint256 available = clientBalances[token][balanceHolder];
        if (amount > available) {
            amount = available;
        }
        require(amount > 0, "AYieldStrategy: no principal to relinquish");

        // Write down recorded principal ONLY — vault shares are deliberately untouched.
        clientBalances[token][balanceHolder] -= amount;
        totalDeposited[token] -= amount;

        emit PrincipalRelinquished(token, balanceHolder, amount, clientBalances[token][balanceHolder]);
    }

    // ============ VAULT-INTERACTION HOOKS (abstract) ============

    /**
     * @notice Acquire backing shares for a deposit and book the resulting principal.
     * @param token The token address (must be underlying token)
     * @param amount The nominal amount of underlying tokens deposited
     * @param recipient The address credited in accounting (clientBalances)
     * @param depositor The address tokens are transferred from
     * @return creditedPrincipal The principal booked against `recipient`
     * @dev Concrete strategies define HOW shares are acquired (direct vault.deposit vs AMM swap) and
     *      how much principal is credited (full nominal vs slippage haircut), then update clientBalances
     *      + totalDeposited accordingly.
     */
    function _depositInternal(address token, uint256 amount, address recipient, address depositor)
        internal
        virtual
        returns (uint256 creditedPrincipal);

    /**
     * @notice Dispose backing shares for a withdrawal and decrement the holder's principal.
     * @param token The token address (must be underlying token)
     * @param amount The amount of underlying tokens to withdraw
     * @param recipient The address that receives the underlying tokens
     * @param balanceHolder The address whose clientBalances are debited
     * @dev Concrete strategies define HOW shares are disposed (direct vault.redeem vs AMM swap).
     *      For standard withdraw(), recipient == balanceHolder.
     */
    function _withdrawInternal(address token, uint256 amount, address recipient, address balanceHolder) internal virtual;

    // ============ INTERNAL HELPER FUNCTIONS ============

    /**
     * @notice Updates the withdrawal status based on current time
     * @param state The withdrawal state to update
     * @param currentTime The current block timestamp
     */
    function _updateWithdrawalStatus(WithdrawalState storage state, uint256 currentTime) internal {
        if (state.status == WithdrawalStatus.Initiated) {
            if (currentTime >= state.initiatedAt + WAITING_PERIOD) {
                if (currentTime <= state.initiatedAt + TOTAL_DURATION) {
                    state.status = WithdrawalStatus.Executable;
                } else {
                    state.status = WithdrawalStatus.Expired;
                }
            }
        } else if (state.status == WithdrawalStatus.Executable) {
            if (currentTime > state.initiatedAt + TOTAL_DURATION) {
                state.status = WithdrawalStatus.Expired;
            }
        }
    }

    /**
     * @notice Initiates a withdrawal (Phase 1)
     * @param token The token address
     * @param client The client address
     * @param state The withdrawal state to initialize
     * @param currentTime The current block timestamp
     */
    function _initiateWithdrawal(address token, address client, WithdrawalState storage state, uint256 currentTime)
        internal
    {
        // Get current balance
        uint256 balance = this.balanceOf(token, client);
        require(balance > 0, "AYieldStrategy: no balance to withdraw");

        // Initialize withdrawal state
        state.initiatedAt = currentTime;
        state.status = WithdrawalStatus.Initiated;
        state.balance = balance;

        uint256 executableAt = currentTime + WAITING_PERIOD;

        emit WithdrawalInitiated(token, client, balance, currentTime, executableAt);
    }

    /**
     * @notice Executes a withdrawal (Phase 2)
     * @param token The token address
     * @param client The client address
     * @param state The withdrawal state to process
     * @param currentTime The current block timestamp
     */
    function _executeWithdrawal(address token, address client, WithdrawalState storage state, uint256 currentTime)
        internal
    {
        uint256 withdrawAmount = state.balance;

        // Reset state before external call to prevent reentrancy issues
        state.status = WithdrawalStatus.None;
        state.initiatedAt = 0;
        state.balance = 0;

        // Execute the actual withdrawal through virtual function
        _totalWithdraw(token, client, withdrawAmount);

        emit WithdrawalExecuted(token, client, withdrawAmount, currentTime);
    }

    /**
     * @notice Converts uint256 to string for error messages
     * @param value The number to convert
     * @return The string representation
     */
    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
