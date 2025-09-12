# Vault-RM

A secure vault contract system extracted from behodler3-tokenlaunch-RM, providing foundational vault functionality with access control and security features.

## Overview

This project contains the core vault contracts that provide:

- **Abstract Vault Contract**: Base vault implementation with security features and access control
- **Multi-client Authorization**: Support for multiple authorized client contracts
- **Owner Access Control**: Emergency functions restricted to contract owner
- **Security Features**: Comprehensive access control and validation

## Architecture

### Core Contracts

- `src/Vault.sol` - Abstract base vault contract with security and access control
- `src/interfaces/IVault.sol` - Vault interface defining core functionality  
- `src/mocks/MockVault.sol` - Concrete test implementation of Vault
- `src/mocks/MockERC20.sol` - Mock ERC20 token for testing

### Key Features

#### Access Control
- **Owner Functions**: `setClient()`, `emergencyWithdraw()` - restricted to contract owner
- **Client Functions**: `deposit()`, `withdraw()` - restricted to authorized client contracts  
- **Multi-client Support**: Multiple contracts can be authorized simultaneously

#### Security
- Zero address validation for all parameters
- Amount validation (must be > 0)
- Balance checks for withdrawals
- Event emission for all state changes

#### Extensibility
- Abstract base contract allows for concrete implementations
- Virtual functions for custom withdrawal logic
- Interface-based design for interoperability

## Dependencies

- **OpenZeppelin Contracts**: Access control (Ownable) and token interfaces
- **Forge-std**: Testing framework

## Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Installation

1. Clone the repository
2. Install dependencies:
```bash
forge install
```

### Build

```bash
forge build
```

### Test

Run all tests:
```bash
forge test
```

Run specific test contract:
```bash
forge test --match-contract VaultSecurityTest
```

### Security Tests

The `VaultSecurityTest.sol` provides comprehensive test coverage including:

- Access control enforcement (owner vs client vs unauthorized users)
- Multi-client authorization scenarios  
- Input validation and edge cases
- Event emission verification
- Integration testing across multiple tokens

## Usage

### Implementing a Concrete Vault

To create a concrete vault implementation, extend the abstract `Vault` contract:

```solidity
import "./Vault.sol";

contract MyVault is Vault {
    constructor(address _owner) Vault(_owner) {}
    
    function deposit(address token, uint256 amount, address recipient) 
        external override onlyAuthorizedClient {
        // Implement deposit logic
    }
    
    function withdraw(address token, uint256 amount, address recipient) 
        external override onlyAuthorizedClient {
        // Implement withdrawal logic  
    }
    
    function _emergencyWithdraw(uint256 amount) internal override {
        // Implement emergency withdrawal logic
    }
}
```

### Access Control Setup

1. Deploy your vault implementation
2. Set authorized client contracts:
```solidity
vault.setClient(bondingCurveAddress, true);  // Authorize
vault.setClient(oldClientAddress, false);    // Revoke
```

## Source Attribution

These contracts were extracted from the behodler3-tokenlaunch-RM project, preserving the security features and multi-client permissioning developed in stories 006 and 008. The extraction maintains all functionality while establishing an independent vault-focused codebase.

## Foundry Reference

This project uses Foundry for development and testing:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

For more information: https://book.getfoundry.sh/