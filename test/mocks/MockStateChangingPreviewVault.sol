// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./MockERC4626Vault.sol";

/**
 * @notice Minimal interface used to make a state-writing call appear `view` at the call site.
 * @dev `touchState` is declared `view` here so a `view` caller may legally invoke it, but the
 *      MockStateChangingPreviewVault implementation actually writes storage. At runtime under a
 *      STATICCALL the write traps with StateChangeDuringStaticCall — the whole point of this mock.
 *      This indirection is required because modern solc forbids a direct `sstore` (or a `.call` /
 *      assembly `call`) inside a `view`-declared function; routing the write through an interface
 *      whose signature lies about mutability is the standard way to model an Autopool-style vault.
 */
interface IStateToucher {
    function touchState() external view;
}

/**
 * @title MockStateChangingPreviewVault
 * @notice Faithful simulation of a Tokemak-Autopool-style ERC4626 vault whose `previewRedeem`
 *         mutates state (it simulates the withdrawal queue) and therefore reverts with
 *         StateChangeDuringStaticCall when invoked through a STATICCALL.
 * @dev Reuses MockERC4626Vault's deposit / convertToAssets / balanceOf math unchanged. Only
 *      `previewRedeem` is overridden (kept `view` to satisfy the overridden base signature and the
 *      ERC4626 surface), and it performs a real storage write via a self-call typed through
 *      IStateToucher (declared `view`) into the genuinely non-view `touchState`. Outside a static
 *      frame the write succeeds and the function returns the same value `convertToAssets` would;
 *      under STATICCALL the inner `sstore` traps and the call reverts. `convertToAssets`
 *      (inherited) stays genuinely static, so the strategy's fixed credit path succeeds.
 */
contract MockStateChangingPreviewVault is MockERC4626Vault {
    /// @notice Storage slot touched on every previewRedeem call (simulates the Autopool
    ///         withdrawal-queue state mutation). Public so the write is unmistakably real.
    uint256 public previewRedeemCounter;

    constructor(string memory _name, string memory _symbol, address underlying_)
        MockERC4626Vault(_name, _symbol, underlying_)
    {}

    /// @inheritdoc MockERC4626Vault
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        // Self-call routed through IStateToucher (declared `view`) so the `view` analyzer permits
        // it, while the actual implementation writes storage. Under STATICCALL the write traps and
        // this reverts (StateChangeDuringStaticCall); otherwise it mutates and returns.
        IStateToucher(address(this)).touchState();
        return convertToAssets(shares);
    }

    /// @notice Genuinely state-mutating helper invoked (via the lying `view` interface) by
    ///         previewRedeem. The `sstore` here is what traps when reached under STATICCALL.
    function touchState() external {
        previewRedeemCounter += 1;
    }
}
