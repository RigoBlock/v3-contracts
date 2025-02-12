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

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/base/hooks/BaseHook.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
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

    // TODO: check move errors to interface?
    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();
    error PositionOwner();
    error RecipientIsNotSmartPool();
    error ReentrantCall();
    error NestedSubPlan();
    error UniV4PositionsLimitExceeded();
    error DirectCallNotAllowed();

    string public constant override requiredVersion = "4.0.0";
    address private immutable _adapter;

    // transient storage slots, only used by this contract
    // bytes32(uint256(keccak256("AUniswapRouter.lock")) - 1)
    bytes32 private constant _LOCK_SLOT = 0x1e2a0e74e761035cb113c1bf11b7fbac06ae91f3a03ce360dda726ba116c216f;
    // bytes32(uint256(keccak256("AUniswapRouter.reentrancy.depth")) - 1)
    bytes32 private constant _REENTRANCY_DEPTH_SLOT =
        0x3921e0fb5d7436d70b7041cccb0d0f543e6b643f41e09aa71450d5e1c5767376;

    address private immutable _uniswapRouter;
    IPositionManager private immutable _positionManager;

    // TODO: should verify that it is ok to make direct calls, as they could potentially modify state of the adapter
    // either we make sure that a constructor value prevents setting, or we require delegatecall, which would prevent
    // view methods from msg.sender other than the pool operator.
    constructor(address _universalRouter, address _v4Posm, address weth) AUniswapDecoder(weth) {
        _uniswapRouter = _universalRouter;
        _positionManager = IPositionManager(_v4Posm);
        _adapter = address(this);
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

    modifier onlyDelegateCall() {
        require(address(this) != _adapter, DirectCallNotAllowed());
        _;
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

    /// @inheritdoc IAUniswapRouter
    /// @notice Is not reentrancy-protected, as will revert in PositionManager.
    /// @dev Delegatecall-only for extra safety, to pervent accidental user liquidity locking.
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external onlyDelegateCall override {
        (bytes calldata actions, bytes[] calldata params) = unlockData.decodeActionsRouterParams();
        assert(actions.length == params.length);
        Parameters memory newParams;
        Position[] memory positions;

        for (uint256 actionIndex = 0; actionIndex < actions.length; actionIndex++) {
            (newParams, positions) =
                _decodePosmAction(uint8(actions[actionIndex]), params[actionIndex], newParams, positions);
        }

        _processRecipients(newParams.recipients);
        _assertTokensOutHavePriceFeed(newParams.tokensOut);
        _safeApproveTokensIn(newParams.tokensIn, address(uniV4Posm()), type(uint256).max);

        try uniV4Posm().modifyLiquidities{value: newParams.value}(unlockData, deadline) {
            _safeApproveTokensIn(newParams.tokensIn, address(uniV4Posm()), 1);
            _processTokenIds(positions);
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
    function _processTokenIds(Position[] memory positions) private {
        // do not load values unless we are writing to storage
        if (positions.length > 0) {
            // update tokenIds in proxy persistent storage.
            TokenIdsSlot storage idsSlot = StorageLib.uniV4TokenIdsSlot();

            for (uint256 i = 0; i < positions.length; i++) {
                if (positions[i].action == Actions.MINT_POSITION) {
                    // Assert hook does not have access to deltas. Hook address is returned for mint ops only.
                    // If moving the following block to protect all actions, make sure hook address is appended.
                    if (positions[i].hook != ZERO_ADDRESS) {
                        Hooks.Permissions memory permissions = BaseHook(positions[i].hook).getHookPermissions();

                        // we prevent hooks to that can access pool liquidity
                        require(
                            !permissions.afterAddLiquidityReturnDelta && !permissions.afterRemoveLiquidityReturnDelta,
                            LiquidityMintHookError(positions[i].hook)
                        );
                    }

                    // mint reverts if tokenId exists, so we can be sure it is unique
                    uint256 storedLength = idsSlot.tokenIds.length;
                    require(storedLength < 255, UniV4PositionsLimitExceeded());
            
                    // position 0 is flag for removed
                    idsSlot.positions[positions[i].tokenId] = ++storedLength;
                    idsSlot.tokenIds.push(positions[i].tokenId);
                    continue;
                } else {
                    // position must be active in pool storage. This means pool cannot modify liquidity created on its behalf.
                    // This is helpful for position retrieval for nav calculations, otherwise we'd have to push it to storage.
                    // If we remove this assertion, we must make sure that the non-nil hook address is appended, as it would
                    // allow action on a potentially malicious hook minted to the pool, and we must make sure pool is position owner.
                    require(idsSlot.positions[positions[i].tokenId] != 0, PositionOwner());

                    if (positions[i].action == Actions.BURN_POSITION) {
                        idsSlot.positions[positions[i].tokenId] = 0;
                        idsSlot.tokenIds.pop();
                        continue;
                    }
                }
            }

            // activate/remove application in proxy persistent storage.
            uint256 appsBitmap = StorageLib.activeApplications().packedApplications;
            uint256 appFlag = uint256(Applications.UNIV4_LIQUIDITY);
            bool isActiveApp = ApplicationsLib.isActiveApplication(appsBitmap, appFlag);

            // we update application status after all tokenIds have been processed
            if (StorageLib.uniV4TokenIdsSlot().tokenIds.length > 0) {
                if (!isActiveApp) {
                    // activate uniV4 liquidity application
                    StorageLib.activeApplications().storeApplication(appFlag);
                }
            } else {
                if (isActiveApp) {
                    // remove uniV4 liquidity application
                    StorageLib.activeApplications().removeApplication(appFlag);
                }
            }
        }
    }

    function _processRecipients(address[] memory recipients) private view {
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] == address(this), RecipientIsNotSmartPool());
        }
    }
}
