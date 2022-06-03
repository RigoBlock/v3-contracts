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

pragma solidity 0.8.14;

import { LibBytes } from "../../../utils/LibBytes/LibBytes.sol";
import { ERC20Face as RigoToken } from "../../../tokens/ERC20/ERC20.sol";
import { RigoblockV3Pool } from "../../../protocol/RigoblockV3Pool.sol";
import { IExchangesAuthority as ExchangesAuthority } from "../../interfaces/IExchangesAuthority.sol";

/// @title SigVerifier - Allows verify whether a transaction has been signed correctly.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract SigVerifier {

    using LibBytes for bytes;

    address public GRGTokenAddress;

    constructor(
        address _GRGTokenAddress)
        public
    {
        GRGTokenAddress = _GRGTokenAddress;
    }

    /// @dev Verifies that a signature is valid.
    /// @param hash Message hash that is signed.
    /// @param signature Proof of signing.
    /// @return Validity of order signature.
    /// @notice mock function whici returns false
    function isValidSignature(
        /* solhint-disable */
        bytes32 hash,
        bytes calldata signature
        /* solhint-disable */
    )
        external
        view
        returns (bool isValid)
    {
        address recoveredEIP712 = returnRecoveredEIP712Internal(hash, signature);
        address recoveredETHSIGN = returnRecoveredETHSIGNInternal(hash, signature);

        if (recoveredEIP712 != address(0)) {
            require(
                isValid = recoveredEIP712 == Drago(address(msg.sender)).owner(),
                "EIP712_SIGNER_INVALID"
            );

            // if operator holds at least 100 GRG, valid, otherwise require whitelisted signer
            if (RigoToken(GRGTokenAddress).balanceOf(Drago(address(msg.sender)).owner()) >= 100 * 10 ** 18) {
                isValid = true;

            } else {
                require(
                    ExchangesAuthority(
                        Drago(address(msg.sender)).getExchangesAuth()
                    )
                    .getExchangeAdapter(address(tx.origin)) != address(0),
                    "VALID_EIP712_BUT_ORIGIN_NOT_WHITELISTED"
                );
            }

        } else if (recoveredETHSIGN != address(0)) {
            require(
                isValid = recoveredETHSIGN == Drago(address(msg.sender)).owner(),
                "EIP712_SIGNER_INVALID"
            );

            // if operator holds at least 100 GRG, valid, otherwise require whitelisted signer
            if (RigoToken(GRGTokenAddress).balanceOf(Drago(address(msg.sender)).owner()) >= 100 * 10 ** 18) {
                isValid = true;

            } else {
                require(
                    ExchangesAuthority(
                        Drago(address(msg.sender)).getExchangesAuth()
                    )
                    .getExchangeAdapter(address(tx.origin)) != address(0),
                    "VALID_ETHSIGN_BUT_ORIGIN_NOT_WHITELISTED"
                );
            }
        }

        revert("SIGNATURE_INVALID2");
    }

    function returnRecoveredEIP712(
        bytes32 hash,
        bytes calldata signature)
        external
        pure
        returns (address recovered)
    {
        return returnRecoveredEIP712Internal(hash, signature);
    }

    function returnRecoveredETHSIGN(
        bytes32 hash,
        bytes calldata signature)
        external
        pure
        returns (address recovered)
    {
        return returnRecoveredETHSIGNInternal(hash, signature);
    }

    // INTERNAL FUNCTIONS

    function returnRecoveredEIP712Internal(
        bytes32 hash,
        bytes memory signature)
        internal
        pure
        returns (address recovered)
    {
        uint8 v;
        bytes32 r;
        bytes32 s;

        v = uint8(signature[0]);
        r = signature.readBytes32(1);
        s = signature.readBytes32(33);

        recovered = ecrecover(
                hash,
                v,
                r,
                s
            );
        return recovered;
    }

    function returnRecoveredETHSIGNInternal(
        bytes32 hash,
        bytes memory signature)
        internal
        pure
        returns (address recovered)
    {
        uint8 v;
        bytes32 r;
        bytes32 s;

        v = uint8(signature[0]);
        r = signature.readBytes32(1);
        s = signature.readBytes32(33);

        recovered = ecrecover(
                keccak256(abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    hash
                )),
                v,
                r,
                s
            );
        return recovered;
    }
}
