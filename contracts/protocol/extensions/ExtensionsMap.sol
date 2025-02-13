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

import {IAuthority} from "../interfaces/IAuthority.sol";
import {StorageLib} from "../libraries/StorageLib.sol";
import {IEApps} from "./adapters/interfaces/IEApps.sol";
import {IEOracle} from "./adapters/interfaces/IEOracle.sol";
import {IEUpgrade} from "./adapters/interfaces/IEUpgrade.sol";
import "./IExtensionsMap.sol";

/// @title ExtensionsMap - Wraps extensions selectors to addresses.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @notice Its deployed address will be different on different chains and change if selectors or mapped addresses change.
contract ExtensionsMap is IExtensionsMap {
    // mapped selectors. When adding a new selector, make sure its mapping to extension address is added below.
    bytes4 private constant _EAPPS_BALANCES_SELECTOR = IEApps.getAppTokenBalances.selector;
    bytes4 private constant _EAPPS_TOKEN_IDS_SELECTOR = IEApps.getUniV4TokenIds.selector;
    bytes4 private constant _EORACLE_CONVERT_AMOUNT_SELECTOR = IEOracle.convertTokenAmount.selector;
    bytes4 private constant _EORACLE_ORACLE_ADDRESS_SELECTOR = IEOracle.getOracleAddress.selector;
    bytes4 private constant _EORACLE_PRICE_FEED_SELECTOR = IEOracle.hasPriceFeed.selector;
    bytes4 private constant _EORACLE_TWAP_SELECTOR = IEOracle.getTwap.selector;
    bytes4 private constant _EUPGRADE_UPGRADE_SELECTOR = IEUpgrade.upgradeImplementation.selector;
    bytes4 private constant _EUPGRADE_GET_BEACON_SELECTOR = IEUpgrade.getBeacon.selector;

    // mapped extensions
    address private immutable _EAPPS;
    address private immutable _EORACLE;
    address private immutable _EUPGRADE;

    struct Extensions {
        address eApps;
        address eOracle;
        address eUpgrade;
    }

    /// @notice Assumes extensions have been correctly initialized.
    /// @dev When adding a new app, modify apps type and assert correct params are passed to the constructor.
    constructor(Extensions memory extensions) {
        _EAPPS = extensions.eApps;
        _EORACLE = extensions.eOracle;
        _EUPGRADE = extensions.eUpgrade;

        // validate immutable constants. Assumes deps are correctly initialized
        assert(_EAPPS_BALANCES_SELECTOR ^ _EAPPS_TOKEN_IDS_SELECTOR == type(IEApps).interfaceId);
        assert(
            _EORACLE_CONVERT_AMOUNT_SELECTOR ^
            _EORACLE_ORACLE_ADDRESS_SELECTOR ^
            _EORACLE_PRICE_FEED_SELECTOR ^
            _EORACLE_TWAP_SELECTOR == type(IEOracle).interfaceId);
        assert(_EUPGRADE_UPGRADE_SELECTOR ^ _EUPGRADE_GET_BEACON_SELECTOR == type(IEUpgrade).interfaceId);
    }

    /// @inheritdoc IExtensionsMap
    /// @dev Should be called by pool with delegatecall
    function getExtensionBySelector(bytes4 selector)
        external
        view
        override
        returns (address extension, bool shouldDelegatecall)
    {
        if (selector == _EAPPS_BALANCES_SELECTOR || selector == _EAPPS_TOKEN_IDS_SELECTOR) {
            extension = _EAPPS;
            shouldDelegatecall = true;
        } else if (
            selector == _EORACLE_CONVERT_AMOUNT_SELECTOR ||
            selector == _EORACLE_ORACLE_ADDRESS_SELECTOR ||
            selector == _EORACLE_PRICE_FEED_SELECTOR ||
            selector == _EORACLE_TWAP_SELECTOR
        ) {
            extension = _EORACLE;
        } else if (selector == _EUPGRADE_UPGRADE_SELECTOR) {
            extension = _EUPGRADE;
            shouldDelegatecall = msg.sender == StorageLib.pool().owner;
        } else if (selector == _EUPGRADE_GET_BEACON_SELECTOR) {
            extension = _EUPGRADE;
        } else {
            return (address(0), false);
        }
    }
}
