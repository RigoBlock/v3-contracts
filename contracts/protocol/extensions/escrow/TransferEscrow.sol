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

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {ISmartPoolState} from "../../interfaces/v4/pool/ISmartPoolState.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {VirtualBalanceLib} from "../../libraries/VirtualBalanceLib.sol";
import {OpType} from "../../types/Crosschain.sol";
import {BaseEscrowContract} from "./BaseEscrowContract.sol";
import {IEscrowContract} from "./IEscrowContract.sol";

/// @title TransferEscrow - Escrow contract for Transfer and Sync operation refunds
/// @notice Manages refunds from failed Transfer/Sync operations with NAV-neutral donations
/// @dev Transfer/Sync operations create virtual balances, so refunds must adjust them to maintain NAV neutrality
contract TransferEscrow is BaseEscrowContract {
    using SafeTransferLib for address;
    using VirtualBalanceLib for address;
    using SafeCast for uint256;

    constructor(address _pool) BaseEscrowContract(_pool) {}

    /// @inheritdoc IEscrowContract
    function opType() external pure override returns (OpType) {
        // This escrow handles both Transfer and Sync operations
        return OpType.Transfer;
    }

    /// @inheritdoc IEscrowContract
    function donateToPool(address token, uint256 amount) external override {
        require(amount > 0, InvalidAmount());
        _donateToPool(token, amount);
    }

    /// @dev Donates tokens to pool and adjusts virtual balance to maintain NAV neutrality
    /// @param token The token to donate
    /// @param amount The amount to donate
    function _donateToPool(address token, uint256 amount) internal override {
        // Transfer tokens to the pool
        if (token == address(0)) {
            // Native token
            (bool success, ) = payable(pool).call{value: amount}("");
            require(success, TransferFailed());
        } else {
            // ERC20 token
            token.safeTransfer(pool, amount);
        }

        // Adjust virtual balance for the specific token: decrease virtual balance to offset the donation
        // This maintains NAV neutrality since the tokens are being donated back
        VirtualBalanceLib.adjustVirtualBalance(token, -(amount.toInt256()));

        emit TokensDonated(token, amount);
    }
}