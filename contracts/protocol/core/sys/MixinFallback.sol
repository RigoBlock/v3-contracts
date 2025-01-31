// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

// TODO: remove commented code
//import "../actions/MixinActions.sol";
import {MixinImmutables} from "../immutable/MixinImmutables.sol";
import {MixinStorage} from "../immutable/MixinStorage.sol";
import {IAuthority} from "../../interfaces/IAuthority.sol";
import {IRigoblockV3PoolFallback} from "../../interfaces/pool/IRigoblockV3PoolFallback.sol";

abstract contract MixinFallback is MixinImmutables, MixinStorage {
    error PoolImplementationDirectCallNotAllowed();
    error PoolMethodNotAllowed();

    // reading immutable through internal method more gas efficient
    modifier onlyDelegateCall() {
        _checkDelegateCall();
        _;
    }

    /* solhint-disable no-complex-fallback */
    /// @inheritdoc IRigoblockV3PoolFallback
    /// @dev Extensions are persistent, while Adapters are upgradable by the governance
    fallback() external payable onlyDelegateCall {
        // TODO: can group in a single tuple
        bytes4 selector = msg.sig;
        address adapter;

        // flag which allows performing a delegatecall in certain scenarios. Will save gas on view methods.
        bool shouldDelegatecall;

        // TODO: verify this is correct, as the EApps will return wrong balances if caller is owner or not
        // which is way too risky
        if (selector == _EAPPS_BALANCES_SELECTOR) {
            adapter = _EAPPS;
            shouldDelegatecall = true;
        } else if (selector == _EAPPS_WRAPPED_NATIVE_SELECTOR) {
            adapter = _EAPPS;
        } else if (
            selector == _EORACLE_CONVERT_AMOUNT_SELECTOR ||
            selector == _EORACLE_ORACLE_ADDRESS_SELECTOR ||
            selector == _EORACLE_PRICE_FEED_SELECTOR ||
            selector == _EORACLE_CROSS_PRICE_SELECTOR
        ) {
            adapter = _EORACLE;
        } else if (selector == _EUPGRADE_UPGRADE_SELECTOR) {
            adapter = _EUPGRADE;
            shouldDelegatecall = true;
        } else {
            adapter = IAuthority(authority).getApplicationAdapter(selector);

            // we check that the method is approved by governance
            require(adapter != _ZERO_ADDRESS, PoolMethodNotAllowed());

            // adapter calls are aimed at pool operator use and for offchain inspection
            shouldDelegatecall = pool().owner == msg.sender;
        }

        assembly {
            calldatacopy(0, 0, calldatasize())
            let success
            if eq(shouldDelegatecall, 1) {
                success := delegatecall(gas(), adapter, 0, calldatasize(), 0, 0)
                returndatacopy(0, 0, returndatasize())
                if eq(success, 0) {
                    revert(0, returndatasize())
                }
                return(0, returndatasize())
            }
            success := staticcall(gas(), adapter, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            // we allow the staticcall to revert with rich error, should we want to add errors to extensions view methods
            if eq(success, 0) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }

    /* solhint-enable no-complex-fallback */

    /// @inheritdoc IRigoblockV3PoolFallback
    receive() external payable onlyDelegateCall {}

    function _checkDelegateCall() private view {
        require(address(this) != _implementation, PoolImplementationDirectCallNotAllowed());
    }
}
