// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title ISurplusWithdrawer
 * @notice Interface for percentage-based surplus withdrawal functionality
 * @dev Provides functions to withdraw a specified percentage of accumulated surplus from vaults
 */
interface ISurplusWithdrawer {
    /**
     * @notice Emitted when surplus is withdrawn from a vault
     * @param vault The vault address from which surplus was withdrawn
     * @param token The token address that was withdrawn
     * @param client The client address whose surplus was withdrawn
     * @param percentage The percentage of surplus that was withdrawn
     * @param amount The actual amount withdrawn
     * @param recipient The address that received the withdrawn surplus
     */
    event SurplusWithdrawn(
        address indexed vault,
        address indexed token,
        address indexed client,
        uint256 percentage,
        uint256 amount,
        address recipient
    );

    /**
     * @notice Withdraw a specified percentage of surplus from a client's vault balance
     * @param vault The vault address to withdraw from
     * @param token The token address to withdraw
     * @param client The client address whose surplus to withdraw
     * @param clientInternalBalance The client's internal accounting balance
     * @param percentage The percentage of surplus to withdraw (1-100)
     * @param recipient The address that will receive the withdrawn surplus
     * @return The amount withdrawn
     * @dev Validates that percentage is between 1 and 100 (inclusive)
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
    ) external returns (uint256);
}
