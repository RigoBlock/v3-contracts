// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {MixinConstants} from "./MixinConstants.sol";
import {ISmartPoolImmutable} from "../../interfaces/v4/pool/ISmartPoolImmutable.sol";
import {IExtensionsMap} from "../../interfaces/IExtensionsMap.sol";

/// @notice Immutables are not assigned a storage slot, can be safely added to this contract.
abstract contract MixinImmutables is MixinConstants {
    error InvalidAuthorityInput();
    error InvalidExtensionsMapInput();

    /// @inheritdoc ISmartPoolImmutable
    address public immutable override authority;

    ///@inheritdoc ISmartPoolImmutable
    address public immutable override wrappedNative;

    ///@inheritdoc ISmartPoolImmutable
    address public immutable override tokenJar;

    // EIP1967 standard, must be immutable to be compile-time constant.
    address internal immutable _implementation;

    IExtensionsMap internal immutable _extensionsMap;

    /// @notice The ExtensionsMap interface is required to implement the expected methods as sanity check.
    constructor(address _authority, address extensionsMap, address _tokenJar) {
        require(_authority.code.length > 0, InvalidAuthorityInput());
        require(extensionsMap.code.length > 0, InvalidExtensionsMapInput());
        authority = _authority;

        _implementation = address(this);

        // initialize extensions mapping and assert it implements `getExtensionBySelector` method
        _extensionsMap = IExtensionsMap(extensionsMap);
        wrappedNative = _extensionsMap.wrappedNative();

        // the token jar input is expected to be correct at deployment, no sanity checks
        tokenJar = _tokenJar;

        // the following assertion will alway be true, as long as IExtensionsMap implements the expected methods.
        assert(
            IExtensionsMap.eApps.selector ^
                IExtensionsMap.eNavView.selector ^
                IExtensionsMap.eOracle.selector ^
                IExtensionsMap.eUpgrade.selector ^
                IExtensionsMap.eAcrossHandler.selector ^
                IExtensionsMap.wrappedNative.selector ^
                IExtensionsMap.getExtensionBySelector.selector ==
                type(IExtensionsMap).interfaceId
        );
    }
}
