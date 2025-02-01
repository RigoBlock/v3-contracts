// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

pragma solidity >=0.8.0 <0.9.0;

import {MixinConstants} from "./MixinConstants.sol";
import {IRigoblockV3PoolImmutable} from "../../interfaces/pool/IRigoblockV3PoolImmutable.sol";
import {IExtensionsMap} from "../../extensions/IExtensionsMap.sol";

/// @notice Immutables are not assigned a storage slot, can be safely added to this contract.
abstract contract MixinImmutables is MixinConstants {
    error InvalidAuthorityInput();
    error InvalidExtensionsMapInput();

    /// @inheritdoc IRigoblockV3PoolImmutable
    address public immutable override authority;

    ///@inheritdoc IRigoblockV3PoolImmutable
    address public immutable override wrappedNative;

    // EIP1967 standard, must be immutable to be compile-time constant.
    address internal immutable _implementation;

    IExtensionsMap internal immutable _extensionsMap;

    constructor(address _authority, address extensionsMap, address _wrappedNative) {
        require(_authority.code.length > 0, InvalidAuthorityInput());
        require(extensionsMap.code.length > 0, InvalidExtensionsMapInput());
        authority = _authority;
        wrappedNative = _wrappedNative;

        _implementation = address(this);

        // initialize extensions mapping and assert it implements `getExtensionBySelector` method
        _extensionsMap = IExtensionsMap(extensionsMap);
        assert(IExtensionsMap.getExtensionBySelector.selector == type(IExtensionsMap).interfaceId);
    }
}
