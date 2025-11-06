// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title ISurplusWithdrawer
 * @notice Interface for percentage-based surplus withdrawal functionality
 * @dev Provides functions to withdraw a specified percentage of accumulated surplus from vaults
 */
interface ISurplusWithdrawer {
    /**
     * @notice Emitted when the contract configuration is updated
     * @param token The token address configured for surplus withdrawal
     * @param vault The vault address configured for surplus withdrawal
     * @param yieldStrategy The yield strategy address configured for surplus withdrawal
     */
    event ConfigurationUpdated(
        address indexed token,
        address indexed vault,
        address indexed yieldStrategy
    );

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
     * @notice Configure the SurplusWithdrawer with token, vault, and yield strategy addresses
     * @param _token The token address for surplus withdrawal
     * @param _vault The vault address (external ERC4626) for surplus withdrawal
     * @param _yieldStrategy The yield strategy address (our adapter) for surplus withdrawal
     * @dev Only callable by owner (recommend multisig)
     *      Configuration can be updated by calling this function again
     *      All addresses must be non-zero
     *      Emits ConfigurationUpdated event
     */
    function configure(address _token, address _vault, address _yieldStrategy) external;

    /**
     * @notice Withdraw a specified percentage of surplus from a client's vault balance
     * @param client The client address whose surplus to withdraw
     * @param clientInternalBalance The client's internal accounting balance
     * @param percentage The percentage of surplus to withdraw (1-100)
     * @param recipient The address that will receive the withdrawn surplus
     * @return The amount withdrawn
     * @dev Validates that percentage is between 1 and 100 (inclusive)
     *      Calculates surplus using SurplusTracker with pre-configured token and vault
     *      Withdraws (surplus * percentage) / 100 using pre-configured YieldStrategy.withdrawFrom()
     *      Reverts if contract is not configured
     */
    function withdrawSurplusPercent(
        address client,
        uint256 clientInternalBalance,
        uint256 percentage,
        address recipient
    ) external returns (uint256);
}
