// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IAutoPool
 * @notice Generic interface for Auto Finance autopool vaults (autoDOLA, autoUSD, autoETH, etc.)
 * @dev Extends ERC4626 standard for yield-bearing vault functionality
 */
interface IAutoPool is IERC4626 {
    /**
     * @notice Returns the MainRewarder contract address for TOKE rewards
     * @return The address of the MainRewarder contract
     */
    function rewarder() external view returns (address);
}
