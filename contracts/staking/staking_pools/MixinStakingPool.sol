// SPDX-License-Identifier: Apache 2.0
/*

  Original work Copyright 2019 ZeroEx Intl.
  Modified work Copyright 2020 Rigo Intl.

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

pragma solidity >=0.5.9 <0.8.0;
pragma experimental ABIEncoderV2;

import "../../utils/owned/IOwnedUninitialized.sol";
import "../../utils/0xUtils/LibSafeMath.sol";
import "../interfaces/IStructs.sol";
import "../sys/MixinAbstract.sol";
import "./MixinStakingPoolRewards.sol";

abstract contract MixinStakingPool is MixinAbstract, MixinStakingPoolRewards {
    using LibSafeMath for uint256;
    using LibSafeDowncast for uint256;

    /// @dev Asserts that the sender is the operator of the input pool.
    /// @param poolId Pool sender must be operator of.
    modifier onlyStakingPoolOperator(bytes32 poolId) {
        _assertSenderIsPoolOperator(poolId);
        _;
    }

    /// @dev Create a new staking pool. The sender will be the staking pal of this pool.
    /// Note that a staking pal must be payable.
    /// @param rigoblockPoolAddress Adds rigoblock pool to the created staking pool for convenience if non-null.
    /// @return poolId The unique pool id generated for this pool.
    // TODO: check what the pool id should be since we are calling it from registry. We must make sure that an upgrade in registry produces same id.
    function createStakingPool(address rigoblockPoolAddress) external override returns (bytes32 poolId) {
        bytes32 rbPoolId = getPoolRegistry().getPoolIdFromAddress(rigoblockPoolAddress);
        require(rbPoolId != bytes32(0), "NON_REGISTERED_RB_POOL_ERROR");
        // TODO: test if following return value is correct or reverts from pool proxy
        // note that an operator must be payable
        address operator = IOwnedUninitialized(rigoblockPoolAddress).owner();

        // add stakingPal, which receives part of operator reward
        address stakingPal = msg.sender;

        // operator initially shares 30% with stakers
        uint32 operatorShare = uint32(700000);

        // staking pal received 10% of operator rewards
        uint32 stakingPalShare = uint32(100000);

        // check that staking pool does not exist and add unique id for this pool
        _assertStakingPoolDoesNotExist(bytes32(rbPoolId));
        poolId = bytes32(rbPoolId);

        // @notice _assertNewOperatorShare if operatorShare, stakingPalShare are inputs after an upgrade

        // create and store pool
        IStructs.Pool memory pool =
            IStructs.Pool({
                operator: operator,
                stakingPal: stakingPal,
                operatorShare: operatorShare,
                stakingPalShare: stakingPalShare
            });
        _poolById[poolId] = pool;

        // Staking pool has been created
        emit StakingPoolCreated(poolId, operator, operatorShare);

        _joinStakingPoolAsRbPoolAccount(poolId, rigoblockPoolAddress);

        return poolId;
    }

    /// @dev Allows the operator to update the staking pal address.
    /// @param poolId Unique id of pool.
    /// @param newStakingPalAddress Address of the new staking pal.
    function setStakingPalAddress(bytes32 poolId, address newStakingPalAddress)
        external
        override
        onlyStakingPoolOperator(poolId)
    {
        IStructs.Pool storage pool = _poolById[poolId];
        require(
            newStakingPalAddress != address(0) && pool.stakingPal != newStakingPalAddress,
            "STAKING_PAL_NULL_OR_SAME_ERROR"
        );
        pool.stakingPal = newStakingPalAddress;
    }

    /// @dev Decreases the operator share for the given pool (i.e. increases pool rewards for members).
    /// @param poolId Unique Id of pool.
    /// @param newOperatorShare The newly decreased percentage of any rewards owned by the operator.
    function decreaseStakingPoolOperatorShare(bytes32 poolId, uint32 newOperatorShare)
        external
        override
        onlyStakingPoolOperator(poolId)
    {
        // load pool and assert that we can decrease
        uint32 currentOperatorShare = _poolById[poolId].operatorShare;
        _assertNewOperatorShare(currentOperatorShare, newOperatorShare);

        // decrease operator share
        _poolById[poolId].operatorShare = newOperatorShare;
        emit OperatorShareDecreased(poolId, currentOperatorShare, newOperatorShare);
    }

    /// @dev Returns a staking pool
    /// @param poolId Unique id of pool.
    function getStakingPool(bytes32 poolId) public view override returns (IStructs.Pool memory) {
        return _poolById[poolId];
    }

    /// @dev Reverts iff a staking pool does not exist.
    /// @param poolId Unique id of pool.
    function _assertStakingPoolExists(bytes32 poolId) internal view {
        require(_poolById[poolId].operator != NIL_ADDRESS, "STAKING_POOL_DOES_NOT_EXIST_ERROR");
    }

    /// @dev Reverts iff a staking pool does exist.
    /// @param poolId Unique id of pool.
    function _assertStakingPoolDoesNotExist(bytes32 poolId) internal view {
        require(_poolById[poolId].operator == NIL_ADDRESS, "STAKING_POOL_ALREADY_EXISTS_ERROR");
    }

    /// @dev Reverts iff the new operator share is invalid.
    /// @param currentOperatorShare Current operator share.
    /// @param newOperatorShare New operator share.
    function _assertNewOperatorShare(uint32 currentOperatorShare, uint32 newOperatorShare) private pure {
        // sanity checks
        if (newOperatorShare > PPM_DENOMINATOR) {
            // operator share must be a valid fraction
            revert("OPERATOR_SHARE_BIGGER_THAN_MAX_ERROR");
        } else if (newOperatorShare > currentOperatorShare) {
            // new share must be less than or equal to the current share
            revert("OPERATOR_SHARE_BIGGER_THAN_CURRENT_ERROR");
        }
    }

    /// @dev Asserts that the sender is the operator of the input pool.
    /// @param poolId Pool sender must be operator of.
    function _assertSenderIsPoolOperator(bytes32 poolId) private view {
        address operator = _poolById[poolId].operator;
        require(msg.sender == operator, "CALLER_NOT_OPERATOR_ERROR");
    }

    /// @dev Allows caller to join a staking pool as a rigoblock pool account.
    /// @param _poold Id of the pool.
    /// @param _rigoblockPoolAccount Address of pool to be added to staking pool.
    function _joinStakingPoolAsRbPoolAccount(bytes32 _poold, address _rigoblockPoolAccount) internal {
        poolIdByRbPoolAccount[_rigoblockPoolAccount] = _poold;
        emit RbPoolStakingPoolSet(_rigoblockPoolAccount, _poold);
    }
}
