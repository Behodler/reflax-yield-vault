// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockMainRewarder
 * @notice Mock implementation of Tokemak's MainRewarder contract for testing
 * @dev Simulates the external Tokemak staking contract that handles TOKE rewards
 *      Supports two modes:
 *      - Simple mode (default): Only tracks balances internally, no actual transfers
 *      - Realistic mode: Actually transfers shares to/from the rewarder
 *      Also supports time-based reward accrual for testing reward functionality
 */
contract MockMainRewarder {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _rewards;
    mapping(address => uint256) private _lastUpdateTime;
    uint256 private _totalSupply;
    address private _rewardToken;
    address private _shareToken; // autoDOLA token address
    bool private _transferShares; // Whether to actually transfer shares or just track internally

    // Reward rate: tokens per second per staked share (scaled by 1e18)
    uint256 public rewardRatePerSecond = 1e14; // 0.0001 tokens per second per share

    constructor(address rewardTokenAddr) {
        _rewardToken = rewardTokenAddr;
        _transferShares = false; // Default to simple mode for backward compatibility
    }

    // Set the share token address (autoDOLA) and enable realistic transfer mode
    function setShareToken(address shareToken) external {
        _shareToken = shareToken;
        _transferShares = true; // Enable transfers when share token is set
    }

    // Allow tests to explicitly control transfer behavior
    function setTransferMode(bool enabled) external {
        _transferShares = enabled;
    }

    function stake(address user, uint256 amount) external {
        // Update rewards before changing balance
        _updateReward(user);

        // In realistic mode, transfer shares from caller to this contract
        if (_transferShares && _shareToken != address(0)) {
            IERC20(_shareToken).transferFrom(msg.sender, address(this), amount);
        }

        _balances[user] += amount;
        _totalSupply += amount;
    }

    function withdraw(address user, uint256 amount, bool claim) external {
        require(_balances[user] >= amount, "Insufficient staked balance");

        // Update rewards before changing balance
        _updateReward(user);

        _balances[user] -= amount;
        _totalSupply -= amount;

        // In realistic mode, transfer shares back to caller
        if (_transferShares && _shareToken != address(0)) {
            IERC20(_shareToken).transfer(msg.sender, amount);
        }

        // If claim is true, also claim pending rewards
        if (claim && _rewards[user] > 0) {
            uint256 reward = _rewards[user];
            _rewards[user] = 0;
            MockERC20(_rewardToken).transfer(user, reward);
        }
    }

    // Internal function to update accumulated rewards based on time
    function _updateReward(address user) internal {
        if (_balances[user] > 0 && _lastUpdateTime[user] > 0) {
            uint256 timeElapsed = block.timestamp - _lastUpdateTime[user];
            uint256 pendingReward = (_balances[user] * rewardRatePerSecond * timeElapsed) / 1e18;
            _rewards[user] += pendingReward;
        }
        _lastUpdateTime[user] = block.timestamp;
    }

    function earned(address user) external view returns (uint256) {
        // Calculate pending rewards including time-based accrual
        uint256 pending = _rewards[user];
        if (_balances[user] > 0 && _lastUpdateTime[user] > 0) {
            uint256 timeElapsed = block.timestamp - _lastUpdateTime[user];
            pending += (_balances[user] * rewardRatePerSecond * timeElapsed) / 1e18;
        }
        return pending;
    }

    function getReward(address account, address recipient, bool claimExtras) external returns (bool) {
        // Update rewards to capture any pending time-based accrual
        _updateReward(account);

        uint256 reward = _rewards[account];
        _rewards[account] = 0;
        if (reward > 0) {
            MockERC20(_rewardToken).transfer(recipient, reward);
        }
        // claimExtras is a parameter for future extensibility, currently just a placeholder
        return true;
    }

    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function rewardToken() external view returns (address) {
        return _rewardToken;
    }

    // Test helper to simulate earning rewards
    function simulateRewards(address user, uint256 amount) external {
        _rewards[user] += amount;
        MockERC20(_rewardToken).mint(address(this), amount);
    }
}
