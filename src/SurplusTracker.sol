// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/ISurplusTracker.sol";
import "./interfaces/IYieldStrategy.sol";

/**
 * @title SurplusTracker
 * @notice Read-only contract to calculate surplus across vault types
 * @dev Provides view functions to determine yield surplus for clients in vaults
 *      Works with ALL vault types, not just AutoDolaYieldStrategy
 */
contract SurplusTracker is ISurplusTracker {
    /**
     * @notice Calculate the surplus for a given client in a vault
     * @param vault The vault address
     * @param token The token address
     * @param client The client address
     * @param clientInternalBalance The client's internal accounting balance
     * @return The surplus amount (vault balance - client internal balance)
     * @dev Surplus represents yield that has accrued in the vault but is not tracked in client's internal accounting
     *      For example: Behodler's virtualInputTokens (internal) vs vault's balanceOf (actual with yield)
     *
     *      The function compares:
     *      - vaultBalance: The actual balance in the vault (includes accumulated yield)
     *      - clientInternalBalance: What the client thinks they have (from their internal accounting)
     *
     *      If vaultBalance > clientInternalBalance, the difference is the surplus (harvestable yield)
     *      If vaultBalance <= clientInternalBalance, there is no surplus (returns 0)
     */
    function getSurplus(
        address vault,
        address token,
        address client,
        uint256 clientInternalBalance
    ) external view override returns (uint256) {
        require(vault != address(0), "SurplusTracker: vault cannot be zero address");
        require(token != address(0), "SurplusTracker: token cannot be zero address");
        require(client != address(0), "SurplusTracker: client cannot be zero address");

        // Get the actual balance in the vault (includes accumulated yield)
        uint256 vaultBalance = IYieldStrategy(vault).balanceOf(token, client);

        // If vault balance is less than or equal to internal balance, no surplus
        if (vaultBalance <= clientInternalBalance) {
            return 0;
        }

        // Calculate surplus as the difference between vault balance and internal balance
        return vaultBalance - clientInternalBalance;
    }
}
