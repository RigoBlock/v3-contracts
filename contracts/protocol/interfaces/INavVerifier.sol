// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2018 RigoBlock, Rigo Investment Sagl.

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

/// @title Nav Verifier Interface - Allows to check if new NAV comes from approved authority.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface INavVerifier {

    /// @dev Verifies that a signature is valid.
    /// @param _unitaryValue Value of 1 token in wei units.
    /// @param _signatureValidUntilBlock Number of blocks.
    /// @param _hash Message hash that is signed.
    /// @param _signedData Proof of nav validity.
    /// @return isValid Bool validity of signed data.
    /// @notice mock function which returns true.
    function isValidNav(
        uint256 _unitaryValue,
        uint256 _signatureValidUntilBlock,
        bytes32 _hash,
        bytes calldata _signedData
    )
        external
        view
        returns (bool isValid);
}
