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

import {IEApps} from "../extensions/adapters/interfaces/IEApps.sol";
import {IEAcrossHandler} from "../extensions/adapters/interfaces/IEAcrossHandler.sol";
import {IEOracle} from "../extensions/adapters/interfaces/IEOracle.sol";
import {IEUpgrade} from "../extensions/adapters/interfaces/IEUpgrade.sol";
import {IAuthority} from "../interfaces/IAuthority.sol";
import {IExtensionsMap} from "../interfaces/IExtensionsMap.sol";
import {IExtensionsMapDeployer} from "../interfaces/IExtensionsMapDeployer.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {DeploymentParams, Extensions} from "../types/DeploymentParams.sol";

/// @title ExtensionsMap - Wraps extensions selectors to addresses.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @notice Its deployed address will be different on different chains and change if selectors or mapped addresses change.
contract ExtensionsMap is IExtensionsMap {
    // mapped selectors. When adding a new selector, make sure its mapping to extension address is added below.
    bytes4 private constant _EAPPS_BALANCES_SELECTOR = IEApps.getAppTokenBalances.selector;
    bytes4 private constant _EAPPS_UNIV4_POSITIONS_SELECTOR = IEApps.getUniV4TokenIds.selector;
    bytes4 private constant _EORACLE_CONVERT_BATCH_AMOUNTS_SELECTOR = IEOracle.convertBatchTokenAmounts.selector;
    bytes4 private constant _EORACLE_CONVERT_AMOUNT_SELECTOR = IEOracle.convertTokenAmount.selector;
    bytes4 private constant _EORACLE_PRICE_FEED_SELECTOR = IEOracle.hasPriceFeed.selector;
    bytes4 private constant _EORACLE_TWAP_SELECTOR = IEOracle.getTwap.selector;
    bytes4 private constant _EUPGRADE_UPGRADE_SELECTOR = IEUpgrade.upgradeImplementation.selector;
    bytes4 private constant _EUPGRADE_GET_BEACON_SELECTOR = IEUpgrade.getBeacon.selector;
    bytes4 private constant _EACROSS_HANDLE_MESSAGE_SELECTOR = IEAcrossHandler.handleV3AcrossMessage.selector;

    /// @inheritdoc IExtensionsMap
    address public immutable override eApps;

    /// @inheritdoc IExtensionsMap
    address public immutable override eOracle;

    /// @inheritdoc IExtensionsMap
    address public immutable override eUpgrade;

    /// @inheritdoc IExtensionsMap
    address public immutable override eAcrossHandler;

    /// @inheritdoc IExtensionsMap
    address public immutable override wrappedNative;

    /// @notice Assumes extensions have been correctly initialized.
    /// @dev When adding a new app, modify apps type and assert correct params are passed to the constructor.
    constructor() {
        DeploymentParams memory params = IExtensionsMapDeployer(msg.sender).parameters();
        eApps = params.extensions.eApps;
        eOracle = params.extensions.eOracle;
        eUpgrade = params.extensions.eUpgrade;
        eAcrossHandler = params.extensions.eAcrossHandler;
        wrappedNative = params.wrappedNative;

        // validate immutable constants. Assumes deps are correctly initialized
        assert(_EAPPS_BALANCES_SELECTOR ^ _EAPPS_UNIV4_POSITIONS_SELECTOR == type(IEApps).interfaceId);
        assert(
            _EORACLE_CONVERT_BATCH_AMOUNTS_SELECTOR ^
                _EORACLE_CONVERT_AMOUNT_SELECTOR ^
                _EORACLE_PRICE_FEED_SELECTOR ^
                _EORACLE_TWAP_SELECTOR ==
                type(IEOracle).interfaceId
        );
        assert(_EUPGRADE_UPGRADE_SELECTOR ^ _EUPGRADE_GET_BEACON_SELECTOR == type(IEUpgrade).interfaceId);
        assert(_EACROSS_HANDLE_MESSAGE_SELECTOR == type(IEAcrossHandler).interfaceId);
    }

    // TODO: check allow delegatecall is msg.sender == acrossSpokePool in EAcrossIntents
    /// @inheritdoc IExtensionsMap
    /// @dev Should be called by pool with delegatecall
    function getExtensionBySelector(
        bytes4 selector
    ) external view override returns (address extension, bool shouldDelegatecall) {
        if (selector == _EAPPS_BALANCES_SELECTOR || selector == _EAPPS_UNIV4_POSITIONS_SELECTOR) {
            extension = eApps;
            shouldDelegatecall = true;
        } else if (
            selector == _EORACLE_CONVERT_BATCH_AMOUNTS_SELECTOR ||
            selector == _EORACLE_CONVERT_AMOUNT_SELECTOR ||
            selector == _EORACLE_PRICE_FEED_SELECTOR ||
            selector == _EORACLE_TWAP_SELECTOR
        ) {
            extension = eOracle;
        } else if (selector == _EUPGRADE_UPGRADE_SELECTOR) {
            extension = eUpgrade;
            shouldDelegatecall = msg.sender == StorageLib.pool().owner;
        } else if (selector == _EUPGRADE_GET_BEACON_SELECTOR) {
            extension = eUpgrade;
        } else if (selector == _EACROSS_HANDLE_MESSAGE_SELECTOR) {
            extension = eAcrossHandler;
            shouldDelegatecall = true;
        } else {
            return (address(0), false);
        }
    }
}
