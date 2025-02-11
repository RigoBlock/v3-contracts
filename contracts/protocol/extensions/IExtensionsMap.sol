// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2025 Rigo Intl.

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

pragma solidity 0.8.28;

/// @title IExtensionsMap - Wraps extensions selectors to addresses.
/// @author Gabriele Rigo - <gab@rigoblock.com>
interface IExtensionsMap {

    /// @notice Returns the map of an extension's selector.
    /// @dev Stores all extensions selectors and addresses in its bytecode for gas efficiency.
    /// @param selector Selector of the function signature.
    /// @return extension Address of the target extensions.
    /// @return shouldDelegatecall Boolean if should maintain context of call or not.
    function getExtensionBySelector(bytes4 selector)
        external
        view
        returns (address extension, bool shouldDelegatecall);
}
