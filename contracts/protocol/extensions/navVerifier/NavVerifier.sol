// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2018-2022 RigoBlock, Rigo Investment Sagl.

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

pragma solidity 0.8.14;

import "../../interfaces/IERC20.sol";

/// @title Nav Verifier - Allows to check if new NAV comes from approved authority.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract NavVerifier {
    /// @dev Verifies that a signature is valid.
    /// @notice Returns true if liquidity at least 3% of total supply.
    /// @param _unitaryValue Value of 1 token in wei units.
    /// @param _signatureValidUntilBlock Number of blocks.
    /// @param _hash Message hash that is signed.
    /// @param _signedData Proof of nav validity.
    /// @return isValid Bool validity of signed data.
    function isValidNav(
        uint256 _unitaryValue,
        uint256 _signatureValidUntilBlock,
        bytes32 _hash,
        bytes calldata _signedData
    ) external view returns (bool isValid) {
        // following line mock to silence solhint warnings
        abi.encodePacked(_signatureValidUntilBlock, _hash, _signedData);
        // TODO: check if baseToken should be moved to immutable storage
        ( , , address baseToken, , ) = getData();
        //address baseToken = address(0);
        uint256 minimumLiquidity = _unitaryValue * totalSupply() / 10**decimals() / 100 * 3;
        if (baseToken == address(0)) {
            isValid = address(this).balance >= minimumLiquidity;
        } else {
            isValid = IERC20(baseToken).balanceOf(address(this)) >= minimumLiquidity;
        }
    }

    function getData() internal view virtual returns (
        string memory poolName,
        string memory poolSymbol,
        address baseToken,
        uint256 unitaryValue,
        uint256 spread
    ) {}

    function totalSupply() internal view virtual returns (uint256) {}

    function decimals() internal view virtual returns (uint8) {}
}
