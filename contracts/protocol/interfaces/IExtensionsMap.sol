// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.28;

/// @title IExtensionsMap - Wraps extensions selectors to addresses.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IExtensionsMap {
    /// @notice Returns the address of the applications extension contract.
    function eApps() external view returns (address);

    /// @notice Returns the address of the navigation view extension contract.
    function eNavView() external view returns (address);

    /// @notice Returns the address of the oracle extension contract
    function eOracle() external view returns (address);

    /// @notice Returns the address of the upgrade extension contract.
    function eUpgrade() external view returns (address);

    /// @notice Returns the address of the cross-chain handler extension contract.
    function eCrosschain() external view returns (address);

    /// @notice Returns the address of the wrapped native token.
    /// @dev It is used for initializing it in the pool implementation immutable storage without passing it in the constructor.
    function wrappedNative() external view returns (address);

    /// @notice Returns the map of an extension's selector.
    /// @dev Stores all extensions selectors and addresses in its bytecode for gas efficiency.
    /// @param selector Selector of the function signature.
    /// @return extension Address of the target extensions.
    /// @return shouldDelegatecall Boolean if should maintain context of call or not.
    function getExtensionBySelector(bytes4 selector) external view returns (address extension, bool shouldDelegatecall);
}
