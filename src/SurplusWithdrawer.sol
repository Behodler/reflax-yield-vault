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
 */
contract SurplusWithdrawer is ISurplusWithdrawer, Ownable {

    // ============ STATE VARIABLES ============

    /// @notice The SurplusTracker contract used to calculate surplus
    ISurplusTracker public immutable surplusTracker;

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

    // ============ PUBLIC FUNCTIONS ============

    /**
     * @notice Withdraw a specified percentage of surplus from a client's vault balance
     * @param vault The vault address to withdraw from
     * @param token The token address to withdraw
     * @param client The client address whose surplus to withdraw
     * @param clientInternalBalance The client's internal accounting balance
     * @param percentage The percentage of surplus to withdraw (1-100)
     * @param recipient The address that will receive the withdrawn surplus
     * @return The amount withdrawn
     * @dev Only the owner can call this function (recommend multisig for owner)
     *      Validates that percentage is between 1 and 100 (inclusive)
     *      Calculates surplus using SurplusTracker
     *      Withdraws (surplus * percentage) / 100 using Vault.withdrawFrom()
     */
    function withdrawSurplusPercent(
        address vault,
        address token,
        address client,
        uint256 clientInternalBalance,
        uint256 percentage,
        address recipient
    ) external override onlyOwner returns (uint256) {
        // Validate inputs
        require(vault != address(0), "SurplusWithdrawer: vault cannot be zero address");
        require(token != address(0), "SurplusWithdrawer: token cannot be zero address");
        require(client != address(0), "SurplusWithdrawer: client cannot be zero address");
        require(recipient != address(0), "SurplusWithdrawer: recipient cannot be zero address");
        require(percentage > 0 && percentage <= 100, "SurplusWithdrawer: percentage must be between 1 and 100");

        // Calculate surplus using SurplusTracker
        uint256 surplus = surplusTracker.getSurplus(vault, token, client, clientInternalBalance);
        require(surplus > 0, "SurplusWithdrawer: no surplus to withdraw");

        // Calculate withdrawal amount: (surplus * percentage) / 100
        uint256 withdrawAmount = (surplus * percentage) / 100;
        require(withdrawAmount > 0, "SurplusWithdrawer: withdraw amount must be greater than zero");

        // Withdraw from vault using withdrawFrom
        IYieldStrategy(vault).withdrawFrom(token, client, withdrawAmount, recipient);

        emit SurplusWithdrawn(vault, token, client, percentage, withdrawAmount, recipient);

        return withdrawAmount;
    }
}
