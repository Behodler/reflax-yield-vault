// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../AYieldStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockVault
 * @notice Mock implementation of AYieldStrategy for testing purposes
 * @dev Tracks token balances internally and simulates deposit/withdrawal behavior with access control
 */
contract MockVault is AYieldStrategy {
    // Mapping of token => user => balance
    mapping(address => mapping(address => uint256)) private balances;
    
    // Track total deposits per token for testing
    mapping(address => uint256) public totalDeposits;

    /**
     * @notice Constructor to initialize the MockVault
     * @param _owner The initial owner of the contract
     */
    constructor(address _owner) AYieldStrategy(_owner) {
        // Constructor logic handled by parent AYieldStrategy
    }

    /**
     * @notice Deposit tokens into the vault (restricted to authorized clients)
     * @param token The token address to deposit
     * @param amount The amount of tokens to deposit
     * @param recipient The address that will own the deposited tokens
     */
    function deposit(address token, uint256 amount, address recipient) external override onlyAuthorizedClient {
        require(token != address(0), "MockVault: token is zero address");
        require(amount > 0, "MockVault: amount is zero");
        require(recipient != address(0), "MockVault: recipient is zero address");
        
        // Transfer tokens from sender to vault
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        // Update internal accounting - balance tracked under the authorized client (caller), not recipient
        balances[token][msg.sender] += amount;
        totalDeposits[token] += amount;
    }

    /**
     * @notice Withdraw tokens from the vault (restricted to authorized clients)
     * @param token The token address to withdraw
     * @param amount The amount of tokens to withdraw
     * @param recipient The address that will receive the tokens
     */
    function withdraw(address token, uint256 amount, address recipient) external override onlyAuthorizedClient {
        require(token != address(0), "MockVault: token is zero address");
        require(amount > 0, "MockVault: amount is zero");
        require(recipient != address(0), "MockVault: recipient is zero address");
        require(balances[token][msg.sender] >= amount, "MockVault: insufficient balance");
        
        // Update internal accounting - balance tracked under the authorized client (caller)
        balances[token][msg.sender] -= amount;
        totalDeposits[token] -= amount;
        
        // Transfer tokens from vault to recipient
        IERC20(token).transfer(recipient, amount);
    }

    /**
     * @notice Get the balance of a token for a specific address
     * @param token The token address
     * @param account The account address
     * @return The token balance
     */
    function balanceOf(address token, address account) external view override returns (uint256) {
        return balances[token][account];
    }

    /**
     * @notice Internal emergency withdraw implementation
     * @param amount The amount of tokens to withdraw
     * @dev For MockVault, we'll assume emergency withdrawal of first available token
     */
    function _emergencyWithdraw(uint256 amount) internal override {
        // For testing purposes, we'll emit an event to track emergency withdrawals
        // In a real vault, this would implement actual token withdrawal logic
        // This is a simplified implementation for testing
        require(amount > 0, "MockVault: emergency withdraw amount must be positive");
        // Implementation would depend on specific token emergency withdrawal requirements
    }

    /**
     * @notice Internal total withdraw implementation for emergency fund migration
     * @param token The token address to withdraw
     * @param client The client address whose tokens to withdraw
     * @param amount The amount to withdraw
     * @dev Transfers the client's entire token balance to the owner (emergency migration)
     */
    function _totalWithdraw(address token, address client, uint256 amount) internal override {
        require(token != address(0), "MockVault: token is zero address");
        require(client != address(0), "MockVault: client is zero address");
        require(amount > 0, "MockVault: amount is zero");
        require(balances[token][client] >= amount, "MockVault: insufficient balance for total withdrawal");

        // Update internal accounting - remove balance from client
        balances[token][client] -= amount;
        totalDeposits[token] -= amount;

        // Transfer tokens from vault to owner (emergency migration)
        IERC20(token).transfer(owner(), amount);
    }

    /**
     * @notice Internal withdrawFrom implementation for authorized surplus withdrawal
     * @param token The token address to withdraw
     * @param client The client address whose balance to withdraw from
     * @param amount The amount to withdraw
     * @param recipient The address that will receive the withdrawn tokens
     * @dev Allows authorized withdrawers to extract surplus from client balances
     */
    function _withdrawFrom(address token, address client, uint256 amount, address recipient) internal override {
        require(token != address(0), "MockVault: token is zero address");
        require(client != address(0), "MockVault: client is zero address");
        require(recipient != address(0), "MockVault: recipient is zero address");
        require(amount > 0, "MockVault: amount is zero");
        require(balances[token][client] >= amount, "MockVault: insufficient balance for withdrawFrom");

        // Update internal accounting - remove balance from client
        balances[token][client] -= amount;
        totalDeposits[token] -= amount;

        // Transfer tokens from vault to recipient (not owner, unlike totalWithdraw)
        IERC20(token).transfer(recipient, amount);
    }

    // Additional helper functions for testing
    function getTotalDeposits(address token) external view returns (uint256) {
        return totalDeposits[token];
    }
}