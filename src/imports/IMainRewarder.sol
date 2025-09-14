// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IMainRewarder
 * @notice Interface for Tokemak's MainRewarder contract that handles TOKE reward staking
 * @dev Used for staking autoDOLA vault shares to earn TOKE rewards
 */
interface IMainRewarder {
    /**
     * @notice Stake vault shares to earn TOKE rewards
     * @param user The address of the user staking
     * @param amount The amount of vault shares to stake
     */
    function stake(address user, uint256 amount) external;

    /**
     * @notice Unstake vault shares and stop earning TOKE rewards
     * @param user The address of the user unstaking
     * @param amount The amount of vault shares to unstake
     */
    function withdraw(address user, uint256 amount) external;

    /**
     * @notice Get the reward earned by a user
     * @param user The address of the user
     * @return The amount of TOKE rewards earned
     */
    function earned(address user) external view returns (uint256);

    /**
     * @notice Claim all earned TOKE rewards
     * @param user The address of the user claiming rewards
     * @return The amount of TOKE tokens claimed
     */
    function getReward(address user) external returns (uint256);

    /**
     * @notice Get the staked balance of a user
     * @param user The address of the user
     * @return The amount of shares staked by the user
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Get the total supply of staked shares
     * @return The total amount of shares staked
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Get the reward token (TOKE) address
     * @return The address of the TOKE token
     */
    function rewardToken() external view returns (address);
}