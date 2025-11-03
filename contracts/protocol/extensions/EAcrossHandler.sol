// SPDX-License-Identifier: Apache-2.0-or-later
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

import {IEAcrossHandler} from "../interfaces/IEAcrossHandler.sol";

contract EAcrossHandler is IEAcrossHandler {
    using SafeCast for uint256;

    error Unauthorized();

    address private constant _ZERO_ADDRESS = address(0);

    SpokePoolInterface public immutable acrossSpokePool;

    address private immutable _wrappedNative;

    constructor(address acrossSpokePoolAddress) {
        acrossSpokePool = SpokePoolInterface(acrossSpokePoolAddress);
        _wrappedNative = acrossSpokePool.wrappedNativeToken();
    }

    enum MessageType {
        Transfer; // nav is unchanged on both chains
        Rebalance; // nav is affected on both chains
    }

    struct ActionsParams {
        address user; // the smart pool
        uint256 initialNav; // the nav on the source chain when first synced via a cross-chain intent
        uint256 poolNav; // the latest nav on the source chain
        MessageType messageType;
    }

    /// @inheritdoc IEAcrossHandler
    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address relayer,
        bytes memory message
    ) external {
        require(msg.sender == acrossSpokePool, Unauthorized());
        ActionsParams memory params = abi.decode(message, (ActionsParams));
    }
}
