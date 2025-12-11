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
import {IERC20} from "../interfaces/IERC20.sol";
import {ISmartPoolImmutable} from "../interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../interfaces/v4/pool/ISmartPoolState.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {SlotDerivation} from "../libraries/SlotDerivation.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {IEOracle} from "./adapters/interfaces/IEOracle.sol";
import {IEAcrossHandler} from "./adapters/interfaces/IEAcrossHandler.sol";

/// @title EAcrossHandler - Handles incoming cross-chain transfers via Across Protocol.
/// @notice This extension manages NAV integrity when receiving cross-chain token transfers.
/// @dev Called via delegatecall from pool when Across SpokePool fills deposits.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract EAcrossHandler is IEAcrossHandler {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SlotDerivation for bytes32;

    // Storage slot constants from MixinConstants
    bytes32 private constant _POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 private constant _VIRTUAL_BALANCES_SLOT = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
    bytes32 private constant _CHAIN_NAV_SPREADS_SLOT = 0xa0c9d7d54ff2fdd3c228763004d60a319012acab15df4dac498e6018b7372dd7;
    
    /// @notice Address of the Across SpokePool contract
    /// @dev Immutable to save gas on verification
    address public immutable acrossSpokePool;
    
    constructor(address _acrossSpokePool) {
        require(_acrossSpokePool != address(0), "INVALID_SPOKE_POOL");
        acrossSpokePool = _acrossSpokePool;
    }

    /// @inheritdoc IEAcrossHandler
    function handleV3AcrossMessage(
        address tokenReceived,
        uint256 amount,
        bytes calldata message
    ) external override {
        // CRITICAL SECURITY CHECK: Verify caller is the Across SpokePool
        // Since this is called via delegatecall, msg.sender is preserved from the original call
        require(msg.sender == acrossSpokePool, UnauthorizedCaller());
        
        // Decode the message
        CrossChainMessage memory params = abi.decode(message, (CrossChainMessage));
        
        // Verify output token has a price feed (requirement #3)
        require(IEOracle(address(this)).hasPriceFeed(tokenReceived), TokenWithoutPriceFeed());
        
        // Unwrap native if requested
        address wrappedNative = ISmartPoolImmutable(address(this)).wrappedNative();
        if (params.unwrapNative && tokenReceived == wrappedNative) {
            IWETH9(wrappedNative).withdraw(amount);
        }
        
        if (params.messageType == MessageType.Transfer) {
            _handleTransferMode(tokenReceived, amount);
        } else if (params.messageType == MessageType.Rebalance) {
            _handleRebalanceMode(amount, params);
        } else if (params.messageType == MessageType.Sync) {
            _handleSyncMode(amount, params);
        } else {
            revert InvalidMessageType();
        }
    }

    /// @dev Handles Transfer mode: creates negative virtual balance to offset NAV increase.
    function _handleTransferMode(address tokenReceived, uint256 amount) private {
        // Get base token for this pool
        address baseToken = StorageLib.pool().baseToken;
        
        // Convert received amount to base token equivalent
        int256 baseTokenAmount = IEOracle(address(this)).convertTokenAmount(
            tokenReceived,
            amount.toInt256(),
            baseToken
        );
        
        // Create negative virtual balance to offset the NAV increase from receiving tokens
        // Tokens are already in the pool (transferred by Across before calling this)
        int256 currentBalance = _getVirtualBalance(baseToken);
        _setVirtualBalance(baseToken, currentBalance - baseTokenAmount);
    }

    /// @dev Handles Rebalance mode: verifies NAV is within tolerance of source chain NAV plus spread.
    function _handleRebalanceMode(uint256 /* amount */, CrossChainMessage memory params) private {
        // Check that chains have been synced
        int256 spread = _getChainNavSpread(params.sourceChainId);
        require(spread != 0, ChainsNotSynced());
        
        // Tokens are already transferred by Across
        // Get current NAV on destination chain (includes received tokens)
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(address(this)).getPoolTokens();
        uint256 destNav = poolTokens.unitaryValue;
        
        // Get decimals from the pool
        uint8 destDecimals = StorageLib.pool().decimals;
        
        // Normalize NAVs to same decimal scale for comparison
        uint256 normalizedSourceNav = _normalizeNav(params.sourceNav, params.sourceDecimals, destDecimals);
        
        // Expected dest NAV = source NAV - spread (spread can be positive or negative)
        int256 expectedDestNav = normalizedSourceNav.toInt256() - spread;
        int256 actualDestNav = destNav.toInt256();
        int256 delta = actualDestNav - expectedDestNav;
        
        // Calculate tolerance
        uint256 tolerance = (normalizedSourceNav * params.navTolerance) / 10000;
        
        // Verify destination NAV is within acceptable range accounting for spread
        require(
            delta >= -(tolerance.toInt256()) && delta <= tolerance.toInt256(),
            NavDeviationTooHigh()
        );
    }
    
    /// @dev Handles Sync mode: records NAV spread between chains.
    function _handleSyncMode(uint256 /* amount */, CrossChainMessage memory params) private {
        // Get current NAV on destination chain (includes received tokens)
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(address(this)).getPoolTokens();
        uint256 destNav = poolTokens.unitaryValue;
        
        // Get decimals from the pool  
        uint8 destDecimals = StorageLib.pool().decimals;
        
        // Normalize source NAV to destination decimals
        uint256 normalizedSourceNav = _normalizeNav(params.sourceNav, params.sourceDecimals, destDecimals);
        
        // Calculate spread: source NAV - destination NAV
        // This represents how much the source chain NAV exceeds destination NAV
        int256 spread = normalizedSourceNav.toInt256() - destNav.toInt256();
        
        // Store spread for source chain ID
        _setChainNavSpread(params.sourceChainId, spread);
        
        // Note: Tokens are transferred but this is just a sync, NAV impact is acceptable
        // Virtual balances are NOT created - tokens remain in pool
    }

    /// @dev Normalizes NAV from source decimals to destination decimals.
    function _normalizeNav(
        uint256 nav,
        uint8 sourceDecimals,
        uint8 destDecimals
    ) private pure returns (uint256) {
        if (sourceDecimals == destDecimals) {
            return nav;
        } else if (sourceDecimals > destDecimals) {
            return nav / (10 ** (sourceDecimals - destDecimals));
        } else {
            return nav * (10 ** (destDecimals - sourceDecimals));
        }
    }

    /// @dev Gets the virtual balance for a token from pool storage.
    function _getVirtualBalance(address token) private view returns (int256 value) {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            value := sload(slot)
        }
    }

    /// @dev Sets the virtual balance for a token in pool storage.
    function _setVirtualBalance(address token, int256 value) private {
        bytes32 slot = _VIRTUAL_BALANCES_SLOT.deriveMapping(token);
        assembly {
            sstore(slot, value)
        }
    }
    
    /// @dev Gets the NAV spread for a specific chain from pool storage.
    function _getChainNavSpread(uint256 chainId) private view returns (int256 spread) {
        bytes32 slot = _CHAIN_NAV_SPREADS_SLOT.deriveMapping(bytes32(chainId));
        assembly {
            spread := sload(slot)
        }
    }
    
    /// @dev Sets the NAV spread for a specific chain in pool storage.
    function _setChainNavSpread(uint256 chainId, int256 spread) private {
        bytes32 slot = _CHAIN_NAV_SPREADS_SLOT.deriveMapping(bytes32(chainId));
        assembly {
            sstore(slot, spread)
        }
    }
}
