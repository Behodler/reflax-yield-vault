// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IVault
 * @notice Interface for vault contract that handles token deposits and withdrawals
 */
interface IVault {
    /**
     * @notice Deposit tokens into the vault
     * @param token The token address to deposit
     * @param amount The amount of tokens to deposit
     * @param recipient The address that will own the deposited tokens
     */
    function deposit(address token, uint256 amount, address recipient) external;

    /**
     * @notice Withdraw tokens from the vault
     * @param token The token address to withdraw
     * @param amount The amount of tokens to withdraw
     * @param recipient The address that will receive the tokens
     */
    function withdraw(address token, uint256 amount, address recipient) external;

    /**
     * @notice Get the balance of a token for a specific address
     * @param token The token address
     * @param account The account address
     * @return The token balance
     */
    function balanceOf(address token, address account) external view returns (uint256);

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
}