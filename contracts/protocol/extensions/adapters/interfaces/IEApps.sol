// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2024 Rigo Intl.

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

import {ExternalApp} from "../../../types/ExternalApp.sol"; 

interface IEApps {
    /// @notice Returns token balances owned in a set of external contracts.
    /// @param packedApplications The uint encoded bitmap flags of the active applications.
    /// @return The arrays of lists of token balances grouped by application type.
    function getAppTokenBalances(uint256 packedApplications) external view returns (ExternalApp[] memory);

    /// @notice Returns the wrapped native token.
    /// @return Address of the wrapped native token.
    /// @dev Used to convert wrapped native to native without using oracle.
    function wrappedNative() external view returns (address);
}