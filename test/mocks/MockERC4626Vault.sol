// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../../src/mocks/MockERC20.sol";

/**
 * @title MockERC4626Vault
 * @notice Mock ERC4626 vault for testing ERC4626YieldStrategy
 * @dev Implements the full ERC4626 interface with configurable share pricing,
 *      yield simulation, and optional entry fees for testing fee-charging vault behavior.
 *      NOTE: This mock is NOT suitable for rebasing vault testing. Rebasing vaults are
 *      explicitly NOT supported by ERC4626YieldStrategy.
 */
contract MockERC4626Vault is MockERC20 {
    uint256 private _totalAssets;
    address private _asset;

    /// @notice Fee in basis points (e.g., 100 = 1%) applied on deposits
    uint256 private _feeBps;

    /// @notice Number of times redeem() has been called (test instrumentation)
    uint256 public redeemCount;

    /**
     * @notice Initialize the mock ERC4626 vault
     * @param _name The name of the vault token
     * @param _symbol The symbol of the vault token
     * @param underlying_ The underlying asset address
     */
    constructor(string memory _name, string memory _symbol, address underlying_) MockERC20(_name, _symbol, 18) {
        _totalAssets = 0;
        _asset = underlying_;
        _feeBps = 0;
    }

    // ============ ERC4626 CORE FUNCTIONS ============

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        // Apply fee: reduce effective assets for share calculation
        uint256 effectiveAssets = _feeBps > 0 ? (assets * (10000 - _feeBps)) / 10000 : assets;
        shares = _convertToSharesInternal(effectiveAssets);
        _mint(receiver, shares);
        _totalAssets += assets; // Total assets tracks full amount (fee stays in vault)

        MockERC20(_asset).transferFrom(msg.sender, address(this), assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address shareOwner) external returns (uint256 assets) {
        require(balanceOf(shareOwner) >= shares, "MockERC4626Vault: insufficient shares");

        redeemCount++;
        assets = _convertToAssetsInternal(shares);
        _burn(shareOwner, shares);
        _totalAssets -= assets;

        MockERC20(_asset).transfer(receiver, assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address shareOwner) external returns (uint256 shares) {
        shares = _convertToSharesInternal(assets);
        require(balanceOf(shareOwner) >= shares, "MockERC4626Vault: insufficient shares");

        _burn(shareOwner, shares);
        _totalAssets -= assets;

        MockERC20(_asset).transfer(receiver, assets);
        return shares;
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = _convertToAssetsInternal(shares);
        _mint(receiver, shares);
        _totalAssets += assets;

        MockERC20(_asset).transferFrom(msg.sender, address(this), assets);
        return assets;
    }

    // ============ ERC4626 VIEW FUNCTIONS ============

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToSharesInternal(assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssetsInternal(shares);
    }

    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }

    function asset() public view returns (address) {
        return _asset;
    }

    // ============ ERC4626 PREVIEW FUNCTIONS ============

    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 effectiveAssets = _feeBps > 0 ? (assets * (10000 - _feeBps)) / 10000 : assets;
        return _convertToSharesInternal(effectiveAssets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssetsInternal(shares);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _convertToSharesInternal(assets);
    }

    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssetsInternal(shares);
    }

    // ============ ERC4626 MAX FUNCTIONS ============

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address shareOwner) public view returns (uint256) {
        return _convertToAssetsInternal(balanceOf(shareOwner));
    }

    function maxRedeem(address shareOwner) public view returns (uint256) {
        return balanceOf(shareOwner);
    }

    // ============ INTERNAL HELPERS ============

    function _convertToSharesInternal(uint256 assets) internal view returns (uint256) {
        if (_totalAssets == 0) return assets;
        return (assets * totalSupply()) / _totalAssets;
    }

    function _convertToAssetsInternal(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        return (shares * _totalAssets) / supply;
    }

    // ============ TESTING HELPERS ============

    /// @notice Simulate yield growth by increasing total assets without minting shares
    function simulateYield(uint256 yieldAmount) external {
        // Mint underlying tokens to the vault to back the yield
        MockERC20(_asset).mint(address(this), yieldAmount);
        _totalAssets += yieldAmount;
    }

    /// @notice Simulate a vault loss (underwater) by decreasing total assets and burning backing,
    ///         without changing share supply. The inverse of simulateYield. Underflow-guarded:
    ///         caps the loss to the available assets/backing.
    function simulateLoss(uint256 lossAmount) external {
        if (lossAmount > _totalAssets) {
            lossAmount = _totalAssets;
        }
        uint256 backing = MockERC20(_asset).balanceOf(address(this));
        uint256 toBurn = lossAmount > backing ? backing : lossAmount;
        if (toBurn > 0) {
            MockERC20(_asset).burn(address(this), toBurn);
        }
        _totalAssets -= lossAmount;
    }

    /// @notice Set deposit fee in basis points (e.g., 100 = 1%)
    function setFeeBps(uint256 newFeeBps) external {
        require(newFeeBps <= 10000, "MockERC4626Vault: fee exceeds 100%");
        _feeBps = newFeeBps;
    }

    /// @notice Get current fee in basis points
    function feeBps() external view returns (uint256) {
        return _feeBps;
    }
}
