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

import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {EnumerableSet, AddressSet, Pool} from "../../libraries/EnumerableSet.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {TransientSlot} from "../../libraries/TransientSlot.sol";
import {Applications, TokenIdsSlot} from "../../types/Applications.sol";
import {IAUniswapRouter, IPositionManager} from "./interfaces/IAUniswapRouter.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {AUniswapDecoder} from "./AUniswapDecoder.sol";

interface IERC721 {
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
}

interface IUniswapRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

/// @title AUniswapRouter - Allows interactions with the Uniswap universal router contracts.
/// @notice This contract is used as a bridge between a Rigoblock smart pool contract and the Uniswap universal router.
/// @dev This contract ensures that tokens approvals are set and removed correctly, and that recipient and tokens are validated.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AUniswapRouter is IAUniswapRouter, AUniswapDecoder {
    type Uint256Slot is bytes32;
    type AddressSlot is bytes32;
    type BooleanSlot is bytes32;

    using CalldataDecoder for bytes;
    using TransientSlot for *;
    using SlotDerivation for bytes32;
    using ApplicationsLib for ApplicationsSlot;
    using EnumerableSet for AddressSet;
    using SafeTransferLib for address;

    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();
    error PositionOwner();
    error RecipientIsNotSmartPool();
    error ReentrantCall();
    error NestedSubPlan();
    error UniV4PositionsLimitExceeded();

    string public constant override requiredVersion = "4.0.0";

    // transient storage slots, only used by this contract
    // bytes32(uint256(keccak256("AUniswapRouter.lock")) - 1)
    bytes32 private constant _LOCK_SLOT = 0x1e2a0e74e761035cb113c1bf11b7fbac06ae91f3a03ce360dda726ba116c216f;
    // bytes32(uint256(keccak256("AUniswapRouter.reentrancy.depth")) - 1)
    bytes32 private constant _REENTRANCY_DEPTH_SLOT =
        0x3921e0fb5d7436d70b7041cccb0d0f543e6b643f41e09aa71450d5e1c5767376;

    // TODO: can import?
    uint256 private constant NIL_VALUE = 0;

    // TODO: check store as inintiate instances
    address private immutable _uniswapRouter;
    IPositionManager private immutable _positionManager;

    // TODO: should verify that it is ok to make direct calls, as they could potentially modify state of the adapter
    // either we make sure that a constructor value prevents setting, or we require delegatecall, which would prevent
    // view methods from msg.sender other than the pool operator.
    constructor(address _universalRouter, address _v4Posm, address weth) AUniswapDecoder(weth) {
        _uniswapRouter = _universalRouter;
        _positionManager = IPositionManager(_v4Posm);
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, TransactionDeadlinePassed());
        _;
    }

    modifier nonReentrant() {
        if (!_lockSlot().asBoolean().tload()) {
            _lockSlot().asBoolean().tstore(true);
        } else {
            require(msg.sender == address(this), ReentrantCall());
        }
        _reentrancyDepthSlot().asUint256().tstore(_reentrancyDepthSlot().asUint256().tload() + 1);
        _;
        _reentrancyDepthSlot().asUint256().tstore(_reentrancyDepthSlot().asUint256().tload() - 1);
        if (_reentrancyDepthSlot().asUint256().tload() == 0) {
            _lockSlot().asBoolean().tstore(false);
        }
    }

    function _lockSlot() private pure returns (bytes32) {
        return _LOCK_SLOT;
    }

    function _reentrancyDepthSlot() private pure returns (bytes32) {
        return _REENTRANCY_DEPTH_SLOT;
    }

    /// @inheritdoc IAUniswapRouter
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external override checkDeadline(deadline) returns (Parameters memory params) {
        return execute(commands, inputs);
    }

    /// @inheritdoc IAUniswapRouter
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs
    ) public override nonReentrant returns (Parameters memory params) {
        assert(commands.length == inputs.length);

        // loop through all given commands, verify their inputs and pass along outputs as defined
        for (uint256 i = 0; i < commands.length; i++) {
            // input sanity check and parameters return
            params = _decodeInput(commands[i], inputs[i], params);
        }

        // only execute when finished decoding inputs
        if (_reentrancyDepthSlot().asUint256().tload() == 1) {
            // early return if recipient is not the caller
            _processRecipients(params.recipients);

            _assertTokensOutHavePriceFeed(params.tokensOut);

            // we approve all the tokens that are exiting the smart pool
            _safeApproveTokensIn(params.tokensIn, uniswapRouter(), type(uint256).max);

            // forward the inputs to the Uniswap universal router
            try IUniswapRouter(uniswapRouter()).execute{value: params.value}(commands, inputs) {
                // we remove allowance without clearing storage
                _safeApproveTokensIn(params.tokensIn, uniswapRouter(), 1);
                return params;
            } catch Error(string memory reason) {
                revert(reason);
            }
        }
    }

    /// @notice Can be not reentrancy-protected, as will revert in PositionManager
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external {
        (bytes calldata actions, bytes[] calldata params) = unlockData.decodeActionsRouterParams();
        assert(actions.length == params.length);
        Parameters memory newParams;

        for (uint256 actionIndex = 0; actionIndex < actions.length; actionIndex++) {
            newParams = _decodePosmAction(uint8(actions[actionIndex]), params[actionIndex], newParams);
        }

        _processRecipients(newParams.recipients);
        _assertTokensOutHavePriceFeed(newParams.tokensOut);
        _safeApproveTokensIn(newParams.tokensIn, address(uniV4Posm()), type(uint256).max);

        try uniV4Posm().modifyLiquidities{value: newParams.value}(unlockData, deadline) {
            _safeApproveTokensIn(newParams.tokensIn, address(uniV4Posm()), 1);
            _processTokenIds(newParams.tokenIds);
            return;
        } catch Error(string memory reason) {
            revert(reason);
        }
    }

    /// @inheritdoc IAUniswapRouter
    function uniV4Posm() public view override(IAUniswapRouter, AUniswapDecoder) returns (IPositionManager) {
        return _positionManager;
    }

    /// @inheritdoc IAUniswapRouter
    function uniswapRouter() public view override returns (address universalRouter) {
        return _uniswapRouter;
    }

    /// @notice An implementation before v4 will be rejected here
    function _assertTokensOutHavePriceFeed(address[] memory tokensOut) private {
        // load active tokens from storage
        AddressSet storage values = StorageLib.activeTokensSet();

        for (uint256 i = 0; i < tokensOut.length; i++) {
            // update storage with new token
            values.addUnique(IEOracle(address(this)), tokensOut[i], StorageLib.pool().baseToken);
        }
    }

    function _safeApproveTokensIn(address[] memory tokensIn, address spender, uint256 amount) private {
        for (uint256 i = 0; i < tokensIn.length; i++) {
            // cannot approve base currency, early return
            if (tokensIn[i].isAddressZero()) {
                continue;
            }

            tokensIn[i].safeApprove(spender, amount);

            // assert no approval inflation exists after removing approval
            if (amount == 1) {
                assert(IERC20(tokensIn[i]).allowance(address(this), uniswapRouter()) == 1);
            }
        }
    }

    /// @dev This is executed after the uniswap Posm deltas have been settled.
    function _processTokenIds(int256[] memory tokenIds) private {
        // do not load values unless we are writing to storage
        if (tokenIds.length > 0) {
            // update tokenIds in proxy persistent storage.
            TokenIdsSlot storage idsSlot = StorageLib.uniV4TokenIdsSlot();

            for (uint256 i = 0; i < tokenIds.length; i++) {
                // positive value is a sentinel for mint
                if (tokenIds[i] > 0) {
                    // mint reverts if tokenId exists, so we can be sure it is unique
                    idsSlot.tokenIds.push(uint256(tokenIds[i]));
                    idsSlot.positions[uint256(tokenIds[i])] = idsSlot.tokenIds.length;
                    continue;
                } else {
                    // invert sign. Negative value is flag for increase liquidity or burn
                    uint256 tokenId = uint256(-tokenIds[i]);

                    // after increasing position, liquidity must be non-nil
                    if (uniV4Posm().getPositionLiquidity(tokenId) > 0) {
                        // we do not allow delegating liquidity actions on behalf of pool
                        require(
                            IERC721(address(uniV4Posm())).ownerOf(tokenId) == address(this),
                            PositionOwner()
                        );
                        continue;
                    } else {
                        // after we burned, liquidity must be nil, so it is safe to remove position from tracked
                        idsSlot.positions[tokenId] = 0;
                        idsSlot.tokenIds.pop();
                        continue;
                    }
                }
            }

            // activate/remove application in proxy persistent storage.
            uint256 appsBitmap = StorageLib.activeApplications().packedApplications;
            uint256 appFlag = uint256(Applications.UNIV4_LIQUIDITY);
            bool isActiveApp = ApplicationsLib.isActiveApplication(appsBitmap, appFlag);

            // TODO: we are reading from storage again, but also asserting tokenIds length even in case of burn?
            // TODO: we should probably update the application when we are either pushing or popping a tokenId?
            if (StorageLib.uniV4TokenIdsSlot().tokenIds.length > 0) {
                require(tokenIds.length < 255, UniV4PositionsLimitExceeded());

                // TODO: pass correct Enum
                // activate uniV4 liquidity application
                //if (!isActiveApp) {
                    // TODO; this one reverts with negative index
                //    StorageLib.activeApplications().storeApplication(appFlag);
                //}
            } else {
                // remove uniV4 liquidity application
                //if (isActiveApp) {
                //    StorageLib.activeApplications().removeApplication(appFlag);
                //}
            }
        }
    }

    function _processRecipients(address[] memory recipients) private view {
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] == address(this), RecipientIsNotSmartPool());
        }
    }
}
