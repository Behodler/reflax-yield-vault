// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/mocks/MockERC20.sol";
import "../../src/imports/IAutoPool.sol";

/**
 * @title MockAutoPool
 * @notice Generic mock implementation of Auto Finance autopool ERC4626 vault for testing
 * @dev Simulates the external Auto Finance vault that AutoPoolYieldStrategy deposits into
 *      Can be used for any autopool (autoDOLA, autoUSD, autoETH, etc.)
 */
contract MockAutoPool is MockERC20, IAutoPool {
    uint256 private _totalAssets;
    address private _asset;
    address private _rewarder;

    // Slippage simulation
    bool private _slippageEnabled;
    uint256 private _slippageReturnAmount;

    /**
     * @notice Initialize the mock autopool vault
     * @param _name The name of the vault token (e.g., "AutoDOLA", "AutoUSD")
     * @param _symbol The symbol of the vault token (e.g., "autoDOLA", "autoUSD")
     * @param _underlying The underlying asset address (e.g., DOLA, USDC)
     * @param rewarder_ The MainRewarder contract address
     */
    constructor(string memory _name, string memory _symbol, address _underlying, address rewarder_)
        MockERC20(_name, _symbol, 18)
    {
        _totalAssets = 0; // Start with no assets - shares will be minted on first deposit
        _asset = _underlying;
        _rewarder = rewarder_;
        _slippageEnabled = false;
        // Note: MockMainRewarder defaults to simple mode (no transfers) for backward compatibility
        // Tests that need realistic transfer behavior should call mainRewarder.setShareToken(autoPool) explicitly
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        _mint(receiver, shares);
        _totalAssets += assets;

        MockERC20(_asset).transferFrom(msg.sender, address(this), assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(balanceOf(owner) >= shares, "Insufficient shares");

        assets = convertToAssets(shares);
        _burn(owner, shares);
        _totalAssets -= assets;

        MockERC20(_asset).transfer(receiver, assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(balanceOf(owner) >= shares, "Insufficient shares");

        _burn(owner, shares);
        _totalAssets -= assets;

        // Handle slippage simulation if enabled
        uint256 transferAmount = _slippageEnabled ? _slippageReturnAmount : assets;
        MockERC20(_asset).transfer(receiver, transferAmount);
        return transferAmount; // Return actual transferred amount (not shares)
    }

    function previewDeposit(uint256 assets) public view returns (uint256 shares) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256 assets) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256 shares) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) public view returns (uint256 assets) {
        return convertToAssets(shares);
    }

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return balanceOf(owner);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        _mint(receiver, shares);
        _totalAssets += assets;

        MockERC20(_asset).transferFrom(msg.sender, address(this), assets);
        return assets;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (_totalAssets == 0) return assets;
        return (assets * totalSupply()) / _totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * _totalAssets) / supply;
    }

    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }

    function asset() public view returns (address) {
        return _asset;
    }

    function rewarder() external view returns (address) {
        return _rewarder;
    }

    // ============ TESTING HELPERS ============

    /// @notice Simulate yield growth
    function simulateYield(uint256 yieldAmount) external {
        _totalAssets += yieldAmount;
    }

    /// @notice Enable/disable slippage simulation for testing
    function setSlippageSimulation(bool enabled, uint256 returnAmount) external {
        _slippageEnabled = enabled;
        _slippageReturnAmount = returnAmount;
    }
}
