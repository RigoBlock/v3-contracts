// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {MixinImmutables} from "../immutable/MixinImmutables.sol";
import {MixinStorage} from "../immutable/MixinStorage.sol";
import {IMinimumVersion} from "../../extensions/adapters/interfaces/IMinimumVersion.sol";
import {IAuthority} from "../../interfaces/IAuthority.sol";
import {ISmartPoolFallback} from "../../interfaces/pool/ISmartPoolFallback.sol";
import {VersionLib} from "../../libraries/VersionLib.sol";

abstract contract MixinFallback is MixinImmutables, MixinStorage {
    using VersionLib for string;

    error ExtensionsMapCallFailed();
    error PoolImplementationDirectCallNotAllowed();
    error PoolMethodNotAllowed();
    error PoolVersionNotSupported();

    // reading immutable through internal method more gas efficient
    modifier onlyDelegateCall() {
        _checkDelegateCall();
        _;
    }

    /* solhint-disable no-complex-fallback */
    /// @inheritdoc ISmartPoolFallback
    /// @dev Extensions are persistent, while adapters are upgradable by the governance.
    /// @dev uses shouldDelegatecall to flag selectors that should prompt a delegatecall.
    fallback() external payable onlyDelegateCall {
        // returns nil target if selector not mapped. Uses delegatecall to preserve context of msg.sender for shouldDelegatecall flag
        (bool success, bytes memory returnData) = address(_extensionsMap).delegatecall(abi.encodeCall(_extensionsMap.getExtensionBySelector, (msg.sig)));
        // TODO: we probably do now need to assert success, as ExtensionsMap is hardcoded
        require(success, ExtensionsMapCallFailed());
        (address target, bool shouldDelegatecall) = abi.decode(returnData, (address, bool));

        if (target == _ZERO_ADDRESS) {
            target = IAuthority(authority).getApplicationAdapter(msg.sig);

            // we check that the method is approved by governance
            require(target != _ZERO_ADDRESS, PoolMethodNotAllowed());

            // use try statement, as previously deployed adapters do not implement the method and are supported
            try IMinimumVersion(target).requiredVersion() returns (string memory required) {
                require(VERSION.isVersionHigherOrEqual(required), PoolVersionNotSupported());
            } catch {}

            // adapter calls are aimed at pool operator use and for offchain inspection
            shouldDelegatecall = pool().owner == msg.sender;
        }

        assembly {
            calldatacopy(0, 0, calldatasize())
            //let success
            if eq(shouldDelegatecall, 1) {
                success := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
                returndatacopy(0, 0, returndatasize())
                if eq(success, 0) {
                    revert(0, returndatasize())
                }
                return(0, returndatasize())
            }
            success := staticcall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            // we allow the staticcall to revert with rich error, should we want to add errors to extensions view methods
            if eq(success, 0) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }

    /* solhint-enable no-complex-fallback */

    /// @inheritdoc ISmartPoolFallback
    receive() external payable onlyDelegateCall {}

    function _checkDelegateCall() private view {
        require(address(this) != _implementation, PoolImplementationDirectCallNotAllowed());
    }
}
