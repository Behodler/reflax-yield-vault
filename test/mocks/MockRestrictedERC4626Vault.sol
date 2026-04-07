// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockRestrictedERC4626Vault
 * @notice Mock ERC4626 vault whose entry points all revert (simulates sUSDe cooldown)
 * @dev Implements the subset of ERC4626 view functions the strategy actually uses
 *      (`asset`, `totalAssets`, `convertToShares`, `convertToAssets`, `balanceOf`,
 *      `totalSupply`). All four entry points (`deposit`, `mint`, `withdraw`, `redeem`)
 *      revert unconditionally with `"MockRestrictedERC4626Vault: cooldown active"`,
 *      matching sUSDe's 7-day cooldown restriction. Test-only helpers:
 *      - `advanceYield(uint256 bps)` appreciates `sharePrice` without touching the
 *        restricted entry points, used to simulate yield accrual.
 *      - `mintShares(address to, uint256 amount)` is a test-only escape hatch so pools
 *        can be pre-funded with vault shares to sell.
 */
contract MockRestrictedERC4626Vault is ERC20 {
    /// @notice The underlying asset (typically MockUSDe in this story's integration test)
    address private immutable _asset;

    /// @notice Internal share price in 1e18 basis. Starts at 1e18 (1:1).
    uint256 public sharePrice;

    /**
     * @notice Initialize the restricted mock vault
     * @param _assetAddress Address of the underlying ERC20 asset
     * @param _name ERC20 name for the vault share token
     * @param _symbol ERC20 symbol for the vault share token
     */
    constructor(address _assetAddress, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        _asset = _assetAddress;
        sharePrice = 1e18;
    }

    // ============ ERC4626 VIEW FUNCTIONS ============

    /// @notice Return the underlying asset address
    function asset() external view returns (address) {
        return _asset;
    }

    /// @notice Return the total assets notionally backing all shares
    function totalAssets() external view returns (uint256) {
        return (totalSupply() * sharePrice) / 1e18;
    }

    /// @notice Convert an amount of assets to the equivalent number of shares
    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / sharePrice;
    }

    /// @notice Convert an amount of shares to the equivalent number of assets
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * sharePrice) / 1e18;
    }

    // ============ RESTRICTED ENTRY POINTS ============

    /// @notice Reverts unconditionally (simulates active cooldown)
    function deposit(uint256, address) external pure returns (uint256) {
        revert("MockRestrictedERC4626Vault: cooldown active");
    }

    /// @notice Reverts unconditionally (simulates active cooldown)
    function mint(uint256, address) external pure returns (uint256) {
        revert("MockRestrictedERC4626Vault: cooldown active");
    }

    /// @notice Reverts unconditionally (simulates active cooldown)
    function withdraw(uint256, address, address) external pure returns (uint256) {
        revert("MockRestrictedERC4626Vault: cooldown active");
    }

    /// @notice Reverts unconditionally (simulates active cooldown)
    function redeem(uint256, address, address) external pure returns (uint256) {
        revert("MockRestrictedERC4626Vault: cooldown active");
    }

    // ============ ERC4626 PREVIEW FUNCTIONS ============
    // Documented choice: preview functions return zero. The strategy does not call them;
    // returning zero rather than reverting keeps any generic ERC4626 introspection benign.

    function previewDeposit(uint256) external pure returns (uint256) {
        return 0;
    }

    function previewMint(uint256) external pure returns (uint256) {
        return 0;
    }

    function previewWithdraw(uint256) external pure returns (uint256) {
        return 0;
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        return 0;
    }

    // ============ TEST-ONLY HELPERS ============

    /**
     * @notice Simulate yield accrual by appreciating the share price
     * @param bps Basis points of appreciation to apply (e.g. 500 = +5%)
     */
    function advanceYield(uint256 bps) external {
        sharePrice = (sharePrice * (10000 + bps)) / 10000;
    }

    /**
     * @notice Mint shares directly to an address (test-only, bypasses the cooldown)
     * @param to Recipient of the minted shares
     * @param amount Number of shares to mint
     */
    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
