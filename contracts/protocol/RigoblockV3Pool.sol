// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

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

pragma solidity 0.8.14;

import {IAuthorityCore as Authority} from "./interfaces/IAuthorityCore.sol";
import {IERC20 as Token} from "./interfaces/IERC20.sol";

import "./IRigoblockV3Pool.sol";
import "./core/immutable/MixinConstants.sol";
import "./core/immutable/MixinImmutables.sol";
import "./core/immutable/MixinStorage.sol";
import "./core/actions/MixinOwnerActions.sol";
import "./core/actions/MixinUserActions.sol";

/// @title RigoblockV3Pool - A set of rules for Rigoblock pools.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract RigoblockV3Pool is
    IRigoblockV3Pool,
    MixinConstants,
    MixinImmutables,
    MixinStorage,
    MixinOwnerActions,
    MixinUserActions
{

    // reading immutable through internal method more gas efficient
    modifier onlyDelegateCall() {
        _checkDelegateCall();
        _;
    }

    modifier onlyUninitialized() {
        // pool proxy is always initialized in the constructor, therefore
        // empty extcodesize means the pool has not been initialized
        address self = address(this);
        uint256 size;
        assembly {
            size := extcodesize(self)
        }
        require(size == 0, "POOL_ALREADY_INITIALIZED_ERROR");
        _;
    }

    /// @notice Owner is initialized to 0 to lock owner actions in this implementation.
    /// @notice Kyc provider set as will effectively lock direct mint/burn actions.
    constructor(address _authority) MixinImmutables(_authority) {
        // must lock implementation after initializing _implementation
        owner = address(0);
        admin.kycProvider == address(1);
    }

    /*
     * CORE FUNCTIONS
     */
    /// @dev Delegate calls to extension.
    // restricting delegatecall to owner effectively locks direct calls
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

    // prevent accidental transfer to implementation
    receive() external payable onlyDelegateCall {}

    // pool can only be initialized at creation, meaning this method cannot be
    //  called directly to implementation.
    function _initializePool(
        string calldata _poolName,
        string calldata _poolSymbol,
        address _baseToken,
        address _owner
    ) external override onlyUninitialized {
        poolData.name = _poolName;
        poolData.symbol = _poolSymbol;
        owner = _owner;
        /// we do not initialize unless values different from default ones
        /// careful with new releases as default values must be returned unless poolData overwritten
        if (_baseToken != address(0)) {
            admin.baseToken = _baseToken;
            uint8 tokenDecimals = Token(_baseToken).decimals();
            assert(tokenDecimals <= 18);
            if (tokenDecimals != _conibaseDecimals) {
                poolData.decimals = tokenDecimals;
                poolData.unitaryValue = 1 * 10**tokenDecimals; // initial value is 1
            }
        }

        emit PoolInitialized(msg.sender, _owner, _poolName, _poolSymbol);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Returns how many pool tokens a user holds.
    /// @param _who Address of the target account.
    /// @return Number of pool.
    function balanceOf(address _who) external view override returns (uint256) {
        return userAccount[_who].balance;
    }

    /// @dev Finds details of this pool.
    /// @return poolName String name of this pool.
    /// @return poolSymbol String symbol of this pool.
    /// @return baseToken Address of base token (0 for coinbase).
    /// @return unitaryValue Value of the token in wei unit.
    /// @return spread Value of the spread from unitary value.
    // TODO: can inheritdoc only if implemented in subcontract
    function getData()
        external
        view
        override
        returns (
            string memory poolName,
            string memory poolSymbol,
            address baseToken,
            uint256 unitaryValue,
            uint256 spread
        )
    {
        // TODO: check if we should reorg return data for client efficiency
        return (
            poolName = name(),
            poolSymbol = symbol(),
            baseToken = admin.baseToken,
            _getUnitaryValue(),
            _getSpread()
        );
    }

    /// @dev Finds the administrative data of the pool.
    /// @return Address of the owner.
    /// @return feeCollector Address of the account where a user collects fees.
    /// @return transactionFee Value of the transaction fee in basis points.
    /// @return minPeriod Number of the minimum holding period for tokens.
    function getAdminData()
        external
        view
        override
        returns (
            // TODO: check if should name returned poolOwner
            address, //owner
            address feeCollector,
            uint256 transactionFee,
            uint32 minPeriod
        )
    {
        return (
            owner,
            // TODO: must return internal method
            admin.feeCollector,
            poolData.transactionFee,
            _getMinPeriod()
        );
    }

    function getKycProvider() external view override returns (address kycProviderAddress) {
        return kycProviderAddress = admin.kycProvider;
    }

    /// @dev Returns the total amount of issued tokens for this pool.
    /// @return Number of tokens.
    function totalSupply() external view override returns (uint256) {
        return poolData.totalSupply;
    }

    function name() public view override returns (string memory) {
        return poolData.name;
    }

    function symbol() public view override returns (string memory) {
        return poolData.symbol;
    }

    /// @dev Decimals are initialized at proxy creation only if base token not null.
    /// @return Number of decimals.
    /// @notice We use this method to save gas on base currency pools.
    function decimals() public view override(IERC20, MixinUserActions) returns (uint8) {
        return poolData.decimals != 0 ? poolData.decimals : _conibaseDecimals;
    }

    /*
     * NON-IMPLEMENTED INTERFACE FUNCTIONS
     */
    function transfer(address _to, uint256 _value) external virtual override returns (bool success) {}

    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) external virtual override returns (bool success) {}

    function approve(address _spender, uint256 _value) external virtual override returns (bool success) {}

    function allowance(address _owner, address _spender) external view virtual override returns (uint256) {}

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Returns the address of the application adapter.
    /// @param _selector Hash of the method signature.
    /// @return Address of the application adapter.
    function _getApplicationAdapter(bytes4 _selector) internal view returns (address) {
        return Authority(authority).getApplicationAdapter(_selector);
    }

    function _checkDelegateCall() private view {
        require(address(this) != _implementation, "POOL_IMPLEMENTATION_DIRECT_CALL_NOT_ALLOWED_ERROR");
    }

    function _getMinPeriod() internal view override returns (uint32) {
        return poolData.minPeriod != 0 ? poolData.minPeriod : MIN_LOCKUP;
    }

    function _getSpread() internal view override returns (uint256) {
        return poolData.spread != 0 ? poolData.spread : INITIAL_SPREAD;
    }

    function _getUnitaryValue() internal view override(MixinUserActions, MixinOwnerActions) returns (uint256) {
        return poolData.unitaryValue != 0 ? poolData.unitaryValue : _coinbaseUnitaryValue;
    }
}
