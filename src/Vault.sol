// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IVault.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Vault
 * @notice Abstract vault contract with security features and access control
 * @dev Provides base implementation for vault contracts with owner and multiple client access control
 */
abstract contract Vault is IVault, Ownable {
    
    // ============ STATE VARIABLES ============
    
    /// @notice Mapping of addresses authorized to deposit/withdraw
    mapping(address => bool) public authorizedClients;
    
    // ============ EVENTS ============
    
    /**
     * @notice Emitted when client authorization is updated
     * @param client The client address whose authorization was changed
     * @param authorized Whether the client is now authorized (true) or not (false)
     */
    event ClientAuthorizationSet(address indexed client, bool authorized);
    
    /**
     * @notice Emitted when an emergency withdrawal is performed
     * @param owner The owner who performed the withdrawal
     * @param amount The amount withdrawn
     */
    event EmergencyWithdraw(address indexed owner, uint256 amount);
    
    // ============ MODIFIERS ============
    
    /**
     * @notice Restricts access to only authorized client contracts
     * @dev Reverts if the caller is not an authorized client address
     */
    modifier onlyAuthorizedClient() {
        require(authorizedClients[msg.sender], "Vault: unauthorized, only authorized clients");
        _;
    }
    
    // ============ CONSTRUCTOR ============
    
    /**
     * @notice Initialize the vault with initial owner
     * @param _owner The initial owner of the contract
     */
    constructor(address _owner) Ownable(_owner) {
        require(_owner != address(0), "Vault: owner cannot be zero address");
    }
    
    // ============ OWNER FUNCTIONS ============
    
    /**
     * @notice Set client authorization for deposit/withdraw operations
     * @param client The address of the client contract
     * @param _auth Whether to authorize (true) or deauthorize (false) the client
     * @dev Only the contract owner can call this function
     */
    function setClient(address client, bool _auth) external override onlyOwner {
        require(client != address(0), "Vault: client cannot be zero address");
        
        authorizedClients[client] = _auth;
        
        emit ClientAuthorizationSet(client, _auth);
    }
    
    /**
     * @notice Emergency withdraw function for owner to withdraw funds
     * @param amount The amount of tokens to withdraw
     * @dev Only the contract owner can call this function. Delegates to internal _emergencyWithdraw
     */
    function emergencyWithdraw(uint256 amount) external override onlyOwner {
        require(amount > 0, "Vault: amount must be greater than zero");
        
        _emergencyWithdraw(amount);
        
        emit EmergencyWithdraw(msg.sender, amount);
    }
    
    // ============ VIRTUAL FUNCTIONS ============
    
    /**
     * @notice Internal emergency withdraw implementation to be overridden by concrete contracts
     * @param amount The amount of tokens to withdraw
     * @dev Must be implemented by concrete vault contracts to define emergency withdrawal logic
     */
    function _emergencyWithdraw(uint256 amount) internal virtual;
    
    // ============ VIRTUAL FUNCTIONS ============
    
    /**
     * @notice Deposit tokens into the vault
     * @param token The token address to deposit
     * @param amount The amount of tokens to deposit
     * @param recipient The address that will own the deposited tokens
     * @dev Must be overridden by concrete contracts - implement onlyAuthorizedClient access control
     */
    function deposit(address token, uint256 amount, address recipient) external virtual override;
    
    /**
     * @notice Withdraw tokens from the vault
     * @param token The token address to withdraw
     * @param amount The amount of tokens to withdraw
     * @param recipient The address that will receive the tokens
     * @dev Must be overridden by concrete contracts - implement onlyAuthorizedClient access control
     */
    function withdraw(address token, uint256 amount, address recipient) external virtual override;
}