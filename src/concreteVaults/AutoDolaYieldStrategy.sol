// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../AYieldStrategy.sol";
import "../imports/IAutoDOLA.sol";
import "../imports/IMainRewarder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AutoDolaYieldStrategy
 * @notice Concrete yield strategy implementation for Tokemak's AutoDola integration
 * @dev Extends AYieldStrategy.sol to provide DOLA token deposits with automatic autoDOLA staking and TOKE reward generation
 */
contract AutoDolaYieldStrategy is AYieldStrategy {
    using SafeERC20 for IERC20;

    // ============ STATE VARIABLES ============

    /// @notice The DOLA token contract
    IERC20 public immutable dolaToken;

    /// @notice The TOKE token contract
    IERC20 public immutable tokeToken;

    /// @notice The autoDOLA vault contract (ERC4626)
    IAutoDOLA public immutable autoDolaVault;

    /// @notice The MainRewarder contract for TOKE rewards
    IMainRewarder public immutable mainRewarder;

    /// @notice Mapping to track each client's DOLA balance equivalent
    mapping(address => mapping(address => uint256)) private clientBalances;

    /// @notice Total DOLA deposited across all clients for a token (should be DOLA)
    mapping(address => uint256) private totalDeposited;

    // ============ EVENTS ============

    /**
     * @notice Emitted when DOLA is deposited and staked in autoDOLA
     * @param token The token address (should be DOLA)
     * @param client The client address making the deposit
     * @param recipient The recipient of the deposited tokens
     * @param amount The amount of DOLA deposited
     * @param sharesReceived The amount of autoDOLA shares received
     */
    event DolaDeposited(
        address indexed token,
        address indexed client,
        address indexed recipient,
        uint256 amount,
        uint256 sharesReceived
    );

    /**
     * @notice Emitted when autoDOLA shares are withdrawn and converted to DOLA
     * @param token The token address (should be DOLA)
     * @param client The client address making the withdrawal
     * @param recipient The recipient of the withdrawn tokens
     * @param amount The amount of DOLA withdrawn
     * @param sharesBurned The amount of autoDOLA shares burned
     */
    event DolaWithdrawn(
        address indexed token,
        address indexed client,
        address indexed recipient,
        uint256 amount,
        uint256 sharesBurned
    );

    /**
     * @notice Emitted when TOKE rewards are claimed by the owner
     * @param recipient The address that received the TOKE rewards
     * @param amount The amount of TOKE rewards claimed
     */
    event TokeRewardsClaimed(address indexed recipient, uint256 amount);

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initialize the AutoDolaVault with required contract addresses
     * @param _owner The owner of the vault
     * @param _dolaToken The DOLA token address
     * @param _tokeToken The TOKE token address
     * @param _autoDolaVault The autoDOLA vault address
     * @param _mainRewarder The MainRewarder address
     */
    constructor(
        address _owner,
        address _dolaToken,
        address _tokeToken,
        address _autoDolaVault,
        address _mainRewarder
    ) Vault(_owner) {
        require(_dolaToken != address(0), "AutoDolaVault: DOLA token cannot be zero address");
        require(_tokeToken != address(0), "AutoDolaVault: TOKE token cannot be zero address");
        require(_autoDolaVault != address(0), "AutoDolaVault: autoDOLA vault cannot be zero address");
        require(_mainRewarder != address(0), "AutoDolaVault: MainRewarder cannot be zero address");

        dolaToken = IERC20(_dolaToken);
        tokeToken = IERC20(_tokeToken);
        autoDolaVault = IAutoDOLA(_autoDolaVault);
        mainRewarder = IMainRewarder(_mainRewarder);

        // Approve autoDOLA vault to spend DOLA tokens
        dolaToken.approve(_autoDolaVault, type(uint256).max);

        // Approve MainRewarder to spend autoDOLA shares
        IERC20(_autoDolaVault).approve(_mainRewarder, type(uint256).max);
    }

    // ============ PUBLIC VIEW FUNCTIONS ============

    /**
     * @notice Get the balance of a token for a specific account
     * @param token The token address (should be DOLA)
     * @param account The account address
     * @return The DOLA equivalent balance using autoDOLA's convertToAssets
     * @dev Implements getUserDOLABalance logic as specified in requirements
     */
    function balanceOf(address token, address account) external view override returns (uint256) {
        require(token == address(dolaToken), "AutoDolaVault: only DOLA token supported");

        uint256 storedBalance = clientBalances[token][account];
        if (storedBalance == 0) {
            return 0;
        }

        // Calculate the current DOLA value using autoDOLA's conversion rate
        // This accounts for yield that has accumulated over time
        uint256 totalShares = mainRewarder.balanceOf(address(this));
        if (totalShares == 0 || totalDeposited[token] == 0) {
            return storedBalance;
        }

        // Calculate user's proportional share of total autoDOLA shares
        uint256 userShares = (totalShares * storedBalance) / totalDeposited[token];

        // Convert autoDOLA shares to DOLA assets (includes yield)
        return autoDolaVault.convertToAssets(userShares);
    }

    /**
     * @notice Get the total amount of DOLA deposited by all clients
     * @param token The token address (should be DOLA)
     * @return The total amount of DOLA deposited
     */
    function getTotalDeposited(address token) external view returns (uint256) {
        return totalDeposited[token];
    }

    /**
     * @notice Get the total autoDOLA shares held by this vault
     * @return The total amount of autoDOLA shares
     */
    function getTotalShares() external view returns (uint256) {
        return autoDolaVault.balanceOf(address(this));
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
     * @notice Deposit DOLA tokens into the vault with automatic autoDOLA staking
     * @param token The token address (must be DOLA)
     * @param amount The amount of DOLA tokens to deposit
     * @param recipient The address that will own the deposited tokens
     * @dev Only authorized clients can call this function
     */
    function deposit(address token, uint256 amount, address recipient) external override onlyAuthorizedClient nonReentrant {
        require(token == address(dolaToken), "AutoDolaVault: only DOLA token supported");
        require(amount > 0, "AutoDolaVault: amount must be greater than zero");
        require(recipient != address(0), "AutoDolaVault: recipient cannot be zero address");

        // Transfer DOLA from client to vault
        dolaToken.safeTransferFrom(msg.sender, address(this), amount);

        // Deposit DOLA into autoDOLA vault to receive shares
        uint256 sharesBefore = autoDolaVault.balanceOf(address(this));
        uint256 sharesReceived = autoDolaVault.deposit(amount, address(this));
        uint256 sharesAfter = autoDolaVault.balanceOf(address(this));

        // Verify shares received
        require(sharesAfter == sharesBefore + sharesReceived, "AutoDolaVault: share calculation mismatch");
        require(sharesReceived > 0, "AutoDolaVault: no shares received");

        // Stake the autoDOLA shares in MainRewarder to earn TOKE rewards
        mainRewarder.stake(address(this), sharesReceived);

        // Update client balance and total deposited
        clientBalances[token][recipient] += amount;
        totalDeposited[token] += amount;

        emit DolaDeposited(token, msg.sender, recipient, amount, sharesReceived);
    }

    /**
     * @notice Withdraw DOLA tokens from the vault
     * @param token The token address (must be DOLA)
     * @param amount The amount of DOLA tokens to withdraw
     * @param recipient The address that will receive the tokens
     * @dev Only authorized clients can call this function
     */
    function withdraw(address token, uint256 amount, address recipient) external override onlyAuthorizedClient nonReentrant {
        require(token == address(dolaToken), "AutoDolaVault: only DOLA token supported");
        require(amount > 0, "AutoDolaVault: amount must be greater than zero");
        require(recipient != address(0), "AutoDolaVault: recipient cannot be zero address");

        // Get current recipient balance (includes yield)
        uint256 currentBalance = this.balanceOf(token, recipient);
        require(amount <= currentBalance, "AutoDolaVault: insufficient balance");

        // Calculate the proportional amount of shares to withdraw
        uint256 totalShares = mainRewarder.balanceOf(address(this));
        require(totalShares > 0, "AutoDolaVault: no shares available");

        // Calculate user's current proportional share
        uint256 userStoredBalance = clientBalances[token][recipient];
        uint256 userCurrentShares = (totalShares * userStoredBalance) / totalDeposited[token];

        // Calculate shares to withdraw based on requested amount vs current balance
        uint256 sharesToWithdraw = (userCurrentShares * amount) / currentBalance;
        require(sharesToWithdraw > 0, "AutoDolaVault: no shares to withdraw");

        // Unstake from MainRewarder first
        mainRewarder.withdraw(address(this), sharesToWithdraw, false);

        // Withdraw from autoDOLA vault
        uint256 dolaBefore = dolaToken.balanceOf(address(this));
        uint256 assetsReceived = autoDolaVault.redeem(sharesToWithdraw, address(this), address(this));
        uint256 dolaAfter = dolaToken.balanceOf(address(this));

        // Verify withdrawal
        require(dolaAfter == dolaBefore + assetsReceived, "AutoDolaVault: DOLA withdrawal mismatch");
        require(assetsReceived >= amount, "AutoDolaVault: insufficient assets received");

        // Update client balance proportionally
        uint256 balanceReduction = (userStoredBalance * amount) / currentBalance;
        clientBalances[token][recipient] -= balanceReduction;
        totalDeposited[token] -= balanceReduction;

        // Transfer DOLA to recipient
        dolaToken.safeTransfer(recipient, amount);

        emit DolaWithdrawn(token, msg.sender, recipient, amount, sharesToWithdraw);
    }

    /**
     * @notice Claim TOKE rewards earned from staking autoDOLA shares
     * @param recipient The address that will receive the TOKE rewards
     * @dev Only the owner can call this function for security
     */
    function claimTokeRewards(address recipient) external onlyOwner {
        require(recipient != address(0), "AutoDolaVault: recipient cannot be zero address");

        uint256 rewardsBefore = tokeToken.balanceOf(address(this));
        bool success = mainRewarder.getReward(address(this), address(this), true);
        uint256 rewardsAfter = tokeToken.balanceOf(address(this));

        require(success, "AutoDolaVault: TOKE reward claim failed");
        uint256 rewardsEarned = rewardsAfter - rewardsBefore;

        if (rewardsEarned > 0) {
            tokeToken.safeTransfer(recipient, rewardsEarned);
            emit TokeRewardsClaimed(recipient, rewardsEarned);
        }
    }

    // ============ INTERNAL VIRTUAL FUNCTION IMPLEMENTATIONS ============

    /**
     * @notice Internal emergency withdraw implementation
     * @param amount The amount of DOLA tokens to withdraw
     * @dev Withdraws DOLA by unstaking and redeeming autoDOLA shares
     */
    function _emergencyWithdraw(uint256 amount) internal override {
        uint256 totalShares = mainRewarder.balanceOf(address(this));
        require(totalShares > 0, "AutoDolaVault: no shares to withdraw");

        // Calculate how many shares needed for the requested DOLA amount
        uint256 totalAssets = autoDolaVault.convertToAssets(totalShares);
        uint256 sharesToWithdraw = totalShares;

        if (amount < totalAssets) {
            sharesToWithdraw = autoDolaVault.convertToShares(amount);
        }

        // Unstake from MainRewarder
        uint256 stakedShares = mainRewarder.balanceOf(address(this));
        if (stakedShares > 0) {
            uint256 toUnstake = sharesToWithdraw > stakedShares ? stakedShares : sharesToWithdraw;
            mainRewarder.withdraw(address(this), toUnstake, false);
        }

        // Redeem from autoDOLA vault
        uint256 assetsReceived = autoDolaVault.redeem(sharesToWithdraw, address(this), address(this));

        // Transfer to owner
        uint256 actualAmount = assetsReceived < amount ? assetsReceived : amount;
        dolaToken.safeTransfer(owner(), actualAmount);
    }

    /**
     * @notice Internal total withdraw implementation for emergency fund migration
     * @param token The token address (must be DOLA)
     * @param client The client address whose tokens to withdraw
     * @param amount The amount to withdraw (from cached balance)
     */
    function _totalWithdraw(address token, address client, uint256 amount) internal override {
        require(token == address(dolaToken), "AutoDolaVault: only DOLA token supported");
        require(amount > 0, "AutoDolaVault: amount must be greater than zero");

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

            // Redeem from autoDOLA vault
            uint256 assetsReceived = autoDolaVault.redeem(sharesToWithdraw, address(this), address(this));

            // Update balances
            clientBalances[token][client] = 0;
            totalDeposited[token] -= clientStoredBalance;

            // Transfer to owner (for manual redistribution)
            dolaToken.safeTransfer(owner(), assetsReceived);
        }
    }

    /**
     * @notice Internal withdrawFrom implementation for authorized surplus withdrawal
     * @param token The token address (must be DOLA)
     * @param client The client address whose balance to withdraw from
     * @param amount The amount to withdraw
     * @param recipient The address that will receive the withdrawn tokens
     * @dev Similar to regular withdraw but allows authorized withdrawers to extract surplus
     */
    function _withdrawFrom(address token, address client, uint256 amount, address recipient) internal override {
        require(token == address(dolaToken), "AutoDolaVault: only DOLA token supported");
        require(amount > 0, "AutoDolaVault: amount must be greater than zero");

        // Get current client balance (includes yield)
        uint256 currentBalance = this.balanceOf(token, client);
        require(amount <= currentBalance, "AutoDolaVault: insufficient balance");

        // Calculate the proportional amount of shares to withdraw
        uint256 totalShares = mainRewarder.balanceOf(address(this));
        require(totalShares > 0, "AutoDolaVault: no shares available");

        // Calculate client's current proportional share
        uint256 clientStoredBalance = clientBalances[token][client];
        uint256 clientCurrentShares = (totalShares * clientStoredBalance) / totalDeposited[token];

        // Calculate shares to withdraw based on requested amount vs current balance
        uint256 sharesToWithdraw = (clientCurrentShares * amount) / currentBalance;
        require(sharesToWithdraw > 0, "AutoDolaVault: no shares to withdraw");

        // Unstake from MainRewarder first
        mainRewarder.withdraw(address(this), sharesToWithdraw, false);

        // Withdraw from autoDOLA vault
        uint256 dolaBefore = dolaToken.balanceOf(address(this));
        uint256 assetsReceived = autoDolaVault.redeem(sharesToWithdraw, address(this), address(this));
        uint256 dolaAfter = dolaToken.balanceOf(address(this));

        // Verify withdrawal
        require(dolaAfter == dolaBefore + assetsReceived, "AutoDolaVault: DOLA withdrawal mismatch");
        require(assetsReceived >= amount, "AutoDolaVault: insufficient assets received");

        // Update client balance proportionally
        uint256 balanceReduction = (clientStoredBalance * amount) / currentBalance;
        clientBalances[token][client] -= balanceReduction;
        totalDeposited[token] -= balanceReduction;

        // Transfer DOLA to recipient (instead of msg.sender as in regular withdraw)
        dolaToken.safeTransfer(recipient, amount);
    }
}