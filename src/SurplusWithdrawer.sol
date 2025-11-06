// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/ISurplusWithdrawer.sol";
import "./interfaces/ISurplusTracker.sol";
import "./interfaces/IYieldStrategy.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SurplusWithdrawer
 * @notice State-changing contract with percentage-based surplus withdrawal functionality
 * @dev Integrates with SurplusTracker to calculate surplus and uses YieldStrategy's withdrawFrom to extract the specified percentage
 *      Works with ALL vault types, not just AutoDolaYieldStrategy
 *      Must be configured with token, vault, and yieldStrategy addresses before withdrawal can occur
 */
contract SurplusWithdrawer is ISurplusWithdrawer, Ownable {

    // ============ STATE VARIABLES ============

    /// @notice The SurplusTracker contract used to calculate surplus
    ISurplusTracker public immutable surplusTracker;

    /// @notice The token address configured for surplus withdrawal
    address public token;

    /// @notice The vault address (external ERC4626) configured for surplus withdrawal
    address public vault;

    /// @notice The yield strategy address (our adapter) configured for surplus withdrawal
    address public yieldStrategy;

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initialize the SurplusWithdrawer with a SurplusTracker and owner
     * @param _surplusTracker The SurplusTracker contract address
     * @param _owner The initial owner of the contract (recommend multisig)
     * @dev Ownable constructor validates _owner != address(0)
     */
    constructor(address _surplusTracker, address _owner) Ownable(_owner) {
        require(_surplusTracker != address(0), "SurplusWithdrawer: tracker cannot be zero address");

        surplusTracker = ISurplusTracker(_surplusTracker);
    }

    // ============ CONFIGURATION FUNCTIONS ============

    /**
     * @notice Configure the SurplusWithdrawer with token, vault, and yield strategy addresses
     * @param _token The token address for surplus withdrawal
     * @param _vault The vault address (external ERC4626) for surplus withdrawal
     * @param _yieldStrategy The yield strategy address (our adapter) for surplus withdrawal
     * @dev Only callable by owner (recommend multisig)
     *      Configuration can be updated by calling this function again
     *      All addresses must be non-zero
     *      Emits ConfigurationUpdated event
     */
    function configure(address _token, address _vault, address _yieldStrategy) external onlyOwner {
        require(_token != address(0), "SurplusWithdrawer: token cannot be zero address");
        require(_vault != address(0), "SurplusWithdrawer: vault cannot be zero address");
        require(_yieldStrategy != address(0), "SurplusWithdrawer: yieldStrategy cannot be zero address");

        token = _token;
        vault = _vault;
        yieldStrategy = _yieldStrategy;

        emit ConfigurationUpdated(_token, _vault, _yieldStrategy);
    }

    // ============ PUBLIC FUNCTIONS ============

    /**
     * @notice Withdraw a specified percentage of surplus from a client's vault balance
     * @param client The client address whose surplus to withdraw
     * @param clientInternalBalance The client's internal accounting balance
     * @param percentage The percentage of surplus to withdraw (1-100)
     * @param recipient The address that will receive the withdrawn surplus
     * @return The amount withdrawn
     * @dev Only the owner can call this function (recommend multisig for owner)
     *      Validates that percentage is between 1 and 100 (inclusive)
     *      Calculates surplus using SurplusTracker with pre-configured token and vault
     *      Withdraws (surplus * percentage) / 100 using pre-configured YieldStrategy.withdrawFrom()
     *      Reverts if contract is not configured
     */
    function withdrawSurplusPercent(
        address client,
        uint256 clientInternalBalance,
        uint256 percentage,
        address recipient
    ) external override onlyOwner returns (uint256) {
        // Validate configuration
        require(token != address(0), "SurplusWithdrawer: not configured - token is zero address");
        require(vault != address(0), "SurplusWithdrawer: not configured - vault is zero address");
        require(yieldStrategy != address(0), "SurplusWithdrawer: not configured - yieldStrategy is zero address");

        // Validate inputs
        require(client != address(0), "SurplusWithdrawer: client cannot be zero address");
        require(recipient != address(0), "SurplusWithdrawer: recipient cannot be zero address");
        require(percentage > 0 && percentage <= 100, "SurplusWithdrawer: percentage must be between 1 and 100");

        // Calculate surplus using SurplusTracker with configured token and vault
        uint256 surplus = surplusTracker.getSurplus(vault, token, client, clientInternalBalance);
        require(surplus > 0, "SurplusWithdrawer: no surplus to withdraw");

        // Calculate withdrawal amount: (surplus * percentage) / 100
        uint256 withdrawAmount = (surplus * percentage) / 100;
        require(withdrawAmount > 0, "SurplusWithdrawer: withdraw amount must be greater than zero");

        // Withdraw from yieldStrategy using withdrawFrom
        IYieldStrategy(yieldStrategy).withdrawFrom(token, client, withdrawAmount, recipient);

        emit SurplusWithdrawn(vault, token, client, percentage, withdrawAmount, recipient);

        return withdrawAmount;
    }
}
