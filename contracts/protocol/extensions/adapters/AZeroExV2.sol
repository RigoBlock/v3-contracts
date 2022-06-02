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

pragma solidity 0.5.0;

/// @title ZeroEx adapter - A helper contract for the ZeroEx exchange.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract AZeroExV2 {

/*
    //relevant functions:
    //approve delegated signer for v2
    //in the case an exchange works on a fork, its adapter must include the below as well

    /// @dev Approves a hash on-chain using any valid signature type.
    /// @notice After presigning a hash, the preSign signature type will become valid for that hash and signer.
    /// @param signerAddress Address that should have signed the given hash.
    /// @param signature Proof that the hash has been signed by signer.
    function preSign(
        bytes32 hash,
        address signerAddress,
        bytes signature
    )
        external
    {
        require(
            isValidSignature(
                hash,
                signerAddress,
                signature
            ),
            "INVALID_SIGNATURE"
        );
        preSigned[hash][signerAddress] = true;
    }

    /// @dev Approves/unnapproves a Validator contract to verify signatures on signer's behalf.
    /// @param validatorAddress Address of Validator contract.
    /// @param approval Approval or disapproval of  Validator contract.
    function setSignatureValidatorApproval(
        address validatorAddress,
        bool approval
    )
        external
    {
        address signerAddress = getCurrentContextAddress();
        allowedValidators[signerAddress][validatorAddress] = approval;
        emit SignatureValidatorApproval(
            signerAddress,
            validatorAddress,
            approval
        );
    }

*/

/*
function fillOrderNoThrow(
        LibOrder.Order memory order,
        uint256 takerAssetFillAmount,
        bytes memory signature
    )

function marketBuyWithWeth(
        LibOrder.Order[] memory orders,
        uint256 makerAssetFillAmount,
        bytes[] memory signatures
    )

*/

}
