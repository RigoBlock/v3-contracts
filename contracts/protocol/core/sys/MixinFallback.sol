// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

//import "../actions/MixinActions.sol";
import "../immutable/MixinImmutables.sol";
import "../immutable/MixinStorage.sol";
import "../../interfaces/IAuthorityCore.sol";

abstract contract MixinFallback is MixinImmutables, MixinStorage {
    // reading immutable through internal method more gas efficient
    modifier onlyDelegateCall() {
        _checkDelegateCall();
        _;
    }

    /// @inheritdoc IRigoblockV3PoolFallback
    // TODO: check if should make this method restricted from direct calls
    fallback() external payable {
        address adapter = _getApplicationAdapter(msg.sig);
        // we check that the method is approved by governance
        require(adapter != address(0), "POOL_METHOD_NOT_ALLOWED_ERROR");

        address poolOwner = owner;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success
            // pool owner can execute a delegatecall to extension, any other caller will perform a staticcall
            if eq(caller(), poolOwner) {
                success := delegatecall(gas(), adapter, 0, calldatasize(), 0, 0)
                returndatacopy(0, 0, returndatasize())
                if eq(success, 0) {
                    revert(0, returndatasize())
                }
                return(0, returndatasize())
            }
            success := staticcall(gas(), adapter, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            // TODO: view methods will never be restricted as onchain data are public, should never revert. We could skip this check
            if eq(success, 0) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }

    /// @inheritdoc IRigoblockV3PoolFallback
    receive() external payable onlyDelegateCall {}

    function _checkDelegateCall() private view {
        require(address(this) != _implementation, "POOL_IMPLEMENTATION_DIRECT_CALL_NOT_ALLOWED_ERROR");
    }

    /// @dev Returns the address of the application adapter.
    /// @param _selector Hash of the method signature.
    /// @return Address of the application adapter.
    function _getApplicationAdapter(bytes4 _selector) private view returns (address) {
        return IAuthorityCore(authority).getApplicationAdapter(_selector);
    }
}
