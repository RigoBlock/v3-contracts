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

// solhint-disable-next-line
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {IAcrossSpokePool} from "../../interfaces/IAcrossSpokePool.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {ISmartPoolActions} from "../../interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../interfaces/v4/pool/ISmartPoolState.sol";
import {AddressSet, EnumerableSet} from "../../libraries/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {OpType, DestinationMessage, SourceMessage} from "../../types/Crosschain.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IAIntents} from "./interfaces/IAIntents.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

/// @title AIntents - Allows cross-chain token transfers via Across Protocol.
/// @notice This adapter enables Rigoblock smart pools to bridge tokens across chains while maintaining NAV integrity.
/// @dev This contract ensures virtual balances are managed to offset NAV changes from cross-chain transfers.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AIntents is IAIntents, IMinimumVersion, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using SafeCast for uint256;
    using SafeCast for int256;
    using EnumerableSet for AddressSet;
    using SlotDerivation for bytes32;

    IAcrossSpokePool public immutable override acrossSpokePool;

    // TODO: check if can inherit these from the implementation constants to avoid manual errors
    bytes32 private constant _VIRTUAL_BALANCES_SLOT = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;

    // TODO: are we not storing anything on the source chain? how will we know it's a OpType.Sync vs .Rebalance when i.e. we always successfully bridge from chain1 to chain2???
    bytes32 private constant _CHAIN_NAV_SPREADS_SLOT = 0xa0c9d7d54ff2fdd3c228763004d60a319012acab15df4dac498e6018b7372dd7;

    address private immutable _IMPLEMENTATION;

    modifier onlyDelegateCall() {
        require(address(this) != _IMPLEMENTATION, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return "HF_4.1.0";
    }

    constructor(address acrossSpokePoolAddress) {
        acrossSpokePool = IAcrossSpokePool(acrossSpokePoolAddress);
        _IMPLEMENTATION = address(this);
    }

    /// @inheritdoc IAIntents
    function depositV3(AcrossParams calldata params) external override nonReentrant onlyDelegateCall {
        // sanity checks
        // TODO: check if we can safely skip this check. Also maybe use unified error + condition
        require(!params.inputToken.isAddressZero(), NullAddress());
        require(params.exclusiveRelayer.isAddressZero(), NullAddress());

        // TODO: check if we can query tokens + base token in 1 call and reading only exact slots, as we're not writing to storage
        if (params.inputToken != StorageLib.pool().baseToken) {
            require(StorageLib.activeTokensSet().isActive(params.inputToken), TokenNotActive());
        }

        // Process message and get encoded result
        DestinationMessage memory dstMsg = _processMessage(
            params.message,
            params.inputToken,
            params.inputAmount
        );

        _safeApproveToken(params.inputToken);
        
        acrossSpokePool.depositV3{value: dstMsg.sourceNativeAmount}(
            address(this),
            address(this),
            params.inputToken,
            params.outputToken,
            params.inputAmount,
            params.outputAmount,
            params.destinationChainId,
            params.exclusiveRelayer,
            params.quoteTimestamp,
            uint32(block.timestamp + acrossSpokePool.fillDeadlineBuffer()), // use the across max allowed deadline
            params.exclusivityDeadline, // this param will not be used by across as the exclusiveRelayer must be the null address TODO: verify it is like this
            abi.encode(dstMsg)
        );
        
        _safeApproveToken(params.inputToken);
    }
    
    /*
     * INTERNAL METHODS
     */
    function _processMessage(
        bytes calldata messageData,
        address inputToken,
        uint256 inputAmount
    ) private returns (DestinationMessage memory) {
        SourceMessage memory srcMsg = abi.decode(messageData, (SourceMessage));

        if (srcMsg.opType == OpType.Transfer) {
            _adjustVirtualBalanceForTransfer(inputToken, inputAmount);
        } else if (srcMsg.opType == OpType.Rebalance) {
            // TODO: fix code and uncomment - after the correct solution has been implemented
            //if (!storedNav[targetChain]) {
            //    srcMsg.opType = OpType.Sync; // but could be OpType.Transfer and we could remove one op type
            //    _adjustVirtualBalanceForTransfer(inputToken, inputAmount);
            //}
        } else if (srcMsg.opType == OpType.Sync) {
            _adjustVirtualBalanceForTransfer(inputToken, inputAmount);
        } else {
            revert InvalidOpType();
        }

        ISmartPoolActions(address(this)).updateUnitaryValue();

        // navTolerance in a client-side input
        return DestinationMessage({
            opType: srcMsg.opType,
            sourceChainId: block.chainid,
            sourceNav: ISmartPoolState(address(this)).getPoolTokens().unitaryValue,
            sourceDecimals: StorageLib.pool().decimals,
            navTolerance: srcMsg.navTolerance > 1000 ? 1000 : srcMsg.navTolerance, // reasonable 10% max tolerance
            shouldUnwrap: srcMsg.shouldUnwrapOnDestination,
            sourceNativeAmount: srcMsg.sourceNativeAmount // TODO: check if we can remove this param from dest message
        });
    }
    
    // TOdo: check if should create virtual balance for actual token instead instead of base token
    /// @dev Adjusts virtual balance for Transfer mode.
    function _adjustVirtualBalanceForTransfer(address inputToken, uint256 inputAmount) private {
        address baseToken = StorageLib.pool().baseToken;
        int256 baseTokenAmount = IEOracle(address(this)).convertTokenAmount(
            inputToken,
            inputAmount.toInt256(),
            baseToken
        );
        _setVirtualBalance(baseToken, _getVirtualBalance(baseToken) + baseTokenAmount);
    }

    /*
     * INTERNAL METHODS
     */
    /// @dev Approves or revokes token approval. If already approved, revokes; otherwise approves max.
    function _safeApproveToken(address token) private {
        if (token.isAddressZero()) return; // Skip if native currency
        
        // TODO: can this fail silently, and are there side effects?
        if (IERC20(token).allowance(address(this), address(acrossSpokePool)) > 0) {
            // Reset to 0 first for tokens that require it (like USDT)
            token.safeApprove(address(acrossSpokePool), 0);
        } else {
            // Approve max amount
            token.safeApprove(address(acrossSpokePool), type(uint256).max);
        }
    }

    // TODO: these methods are identical in EAcrossHandler, should be implemented in a library and imported
    /// @dev Gets the virtual balance for a token from storage.
    function _getVirtualBalance(address token) private view returns (int256 value) {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            value := sload(slot)
        }
    }

    /// @dev Sets the virtual balance for a token.
    function _setVirtualBalance(address token, int256 value) private {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            sstore(slot, value)
        }
    }
}
