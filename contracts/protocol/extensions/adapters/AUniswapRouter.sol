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
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721Enumerable as IERC721} from "forge-std/interfaces/IERC721.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {EnumerableSet, AddressSet, Pool} from "../../libraries/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {TransientSlot} from "../../libraries/TransientSlot.sol";
import {Applications, TokenIdsSlot} from "../../types/Applications.sol";
import {IAUniswapRouter, IPositionManager} from "./interfaces/IAUniswapRouter.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";
import {AUniswapDecoder} from "./AUniswapDecoder.sol";

interface IUniswapRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

interface IPermit2Forwarder {
    function permit2() external view returns (IAllowanceTransfer);
}

/// @title AUniswapRouter - Allows interactions with the Uniswap universal router contracts.
/// @notice This contract is used as a bridge between a Rigoblock smart pool contract and the Uniswap universal router.
/// @dev This contract ensures that tokens approvals are set and removed correctly, and that recipient and tokens are validated.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AUniswapRouter is IAUniswapRouter, IMinimumVersion, AUniswapDecoder, ReentrancyGuardTransient {
    using CalldataDecoder for bytes;
    using ApplicationsLib for ApplicationsSlot;
    using EnumerableSet for AddressSet;
    using SafeTransferLib for address;

    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();

    /// @notice Thrown when the pool is not the position owner
    error PositionOwner();

    /// @notice Thrown when the pool is not the recipient
    error RecipientNotSmartPoolOrRouter();

    /// @notice Thrown when the pool reached maximum number of liquidity positions
    error UniV4PositionsLimitExceeded();

    /// @notice Thrown when a call is made to the adapter directly
    error DirectCallNotAllowed();

    /// @notice Thrown when a pool hook can access liquidity deltas
    error LiquidityMintHookError(address hook);

    /// @notice Thrown when the pool does not hold enough balance
    error InsufficientNativeBalance();

    /// @notice Thrown when the calldata contains both mint and increase for the same tokenId
    error PositionDoesNotExist();

    string private constant _REQUIRED_VERSION = "4.0.0";

    address private immutable _adapter;
    IUniswapRouter private immutable _uniswapRouter;
    IAllowanceTransfer private immutable _permit2;

    constructor(address universalRouter, address v4Posm, address weth) AUniswapDecoder(weth, v4Posm) {
        _uniswapRouter = IUniswapRouter(universalRouter);
        _permit2 = IPermit2Forwarder(v4Posm).permit2();
        _adapter = address(this);
    }

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, TransactionDeadlinePassed());
        _;
    }

    modifier onlyDelegateCall() {
        require(address(this) != _adapter, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    /// @inheritdoc IAUniswapRouter
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external override checkDeadline(deadline) {
        return execute(commands, inputs);
    }

    /// @inheritdoc IAUniswapRouter
    function execute(bytes calldata commands, bytes[] calldata inputs) public override nonReentrant onlyDelegateCall {
        assert(commands.length == inputs.length);
        Parameters memory params;

        // loop through all given commands, verify their inputs and pass along outputs as defined
        for (uint256 i = 0; i < commands.length; i++) {
            // input sanity check and parameters return
            params = _decodeInput(commands[i], inputs[i], params);
        }

        _processRecipients(params.recipients);
        _assertTokensOutHavePriceFeed(params.tokensOut);
        _safeApproveTokensIn(params.tokensIn, address(_uniswapRouter));

        // forward the inputs to the Uniswap universal router
        try _uniswapRouter.execute{value: params.value}(commands, inputs) {
            return;
        } catch Error(string memory reason) {
            revert(reason);
        } catch (bytes memory returnData) {
            if (params.value > address(this).balance) {
                revert InsufficientNativeBalance();
            } else {
                revert(string(returnData));
            }
        }
    }

    /// @inheritdoc IAUniswapRouter
    /// @notice Is not reentrancy-protected, as will revert in PositionManager.
    /// @dev Delegatecall-only for extra safety, to pervent accidental user liquidity locking.
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external override onlyDelegateCall {
        (bytes calldata actions, bytes[] calldata params) = unlockData.decodeActionsRouterParams();
        assert(actions.length == params.length);
        Parameters memory newParams;
        Position[] memory positions;

        for (uint256 actionIndex = 0; actionIndex < actions.length; actionIndex++) {
            (newParams, positions) = _decodePosmAction(
                uint8(actions[actionIndex]),
                params[actionIndex],
                newParams,
                positions
            );
        }

        _processRecipients(newParams.recipients);
        _assertTokensOutHavePriceFeed(newParams.tokensOut);
        _safeApproveTokensIn(newParams.tokensIn, address(_uniV4Posm));

        // read nextTokenId from Posm only if one of the decoded actions is mint position
        uint256 nextTokenIdBefore;
        bool containsMint = _containsMintAction(positions);

        if (containsMint) {
            nextTokenIdBefore = _uniV4Posm.nextTokenId();
        }

        try _uniV4Posm.modifyLiquidities{value: newParams.value}(unlockData, deadline) {
            _processTokenIds(positions, nextTokenIdBefore, containsMint ? _uniV4Posm.nextTokenId() : nextTokenIdBefore);
            return;
        } catch Error(string memory reason) {
            revert(reason);
        } catch {
            if (newParams.value > address(this).balance) {
                revert InsufficientNativeBalance();
            }
        }
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

    /// @dev Some tokens only approve up to type(uint96).max, so we check if approval is less than that amount and approve max uint256 otherwise.
    function _safeApproveTokensIn(address[] memory tokensIn, address target) private {
        for (uint256 i = 0; i < tokensIn.length; i++) {
            // cannot approve base currency, early return
            if (tokensIn[i].isAddressZero()) {
                continue;
            }

            // only approve once, permit2 will handle transaction block approval
            if (IERC20(tokensIn[i]).allowance(address(this), address(_permit2)) < type(uint96).max) {
                tokensIn[i].safeApprove(address(_permit2), type(uint256).max);
            }

            // expiration is set to 0 so that every transaction has an approval valid only for the transaction block
            _permit2.approve(tokensIn[i], target, type(uint160).max, 0);
        }
    }

    /// @dev Executed after the uniswap Posm call, so we can compare before and after state.
    function _processTokenIds(
        Position[] memory positions,
        uint256 nextTokenIdBefore,
        uint256 nextTokenIdAfter
    ) private {
        TokenIdsSlot storage idsSlot = StorageLib.uniV4TokenIdsSlot();

        // store new tokenIds if we have minted new positions
        if (nextTokenIdAfter > nextTokenIdBefore) {
            uint256 storedLength = idsSlot.tokenIds.length;

            // on mint, decoder returns null tokenId, as we cannot reliably retrieve it from the Posm contract
            for (uint256 i = nextTokenIdBefore; i < nextTokenIdAfter; i++) {
                // update storage if it has not been burnt in the same transaction
                if (
                    PositionInfo.unwrap(_uniV4Posm.positionInfo(i)) !=
                    PositionInfo.unwrap(PositionInfoLibrary.EMPTY_POSITION_INFO)
                ) {
                    // increase counter. Position 0 is reserved flag for removed position
                    if (storedLength++ == 0) {
                        // activate uniV4 liquidity application
                        StorageLib.activeApplications().storeApplication(uint256(Applications.UNIV4_LIQUIDITY));
                    }

                    idsSlot.positions[i] = storedLength;
                    idsSlot.tokenIds.push(i);
                }
            }

            // store the position. Mint reverts in uniswap if tokenId exists, so we can be sure it is unique
            require(storedLength <= EnumerableSet._MAX_UNIQUE_VALUES / 2, UniV4PositionsLimitExceeded());
        }

        if (positions.length > 0) {
            for (uint256 i = 0; i < positions.length; i++) {
                if (positions[i].action == Actions.MINT_POSITION) {
                    // Assert hook does not have access to deltas. Hook address is returned for mint ops only.
                    // Notice: if moving the following block to protect all actions, make sure hook address is appended.
                    if (positions[i].hook != ZERO_ADDRESS) {
                        Hooks.Permissions memory permissions = BaseHook(positions[i].hook).getHookPermissions();

                        // we prevent hooks to that can access pool liquidity
                        require(
                            !permissions.afterAddLiquidityReturnDelta && !permissions.afterRemoveLiquidityReturnDelta,
                            LiquidityMintHookError(positions[i].hook)
                        );
                    }
                    continue;
                } else {
                    // position must be active in pool storage for all the following actions.
                    require(idsSlot.positions[positions[i].tokenId] != 0, PositionOwner());

                    if (positions[i].action == Actions.INCREASE_LIQUIDITY) {
                        // as we must append value for native pairs before forwarding the call, the position must exist in the Posm contract
                        require(positions[i].hook != NON_EXISTENT_POSITION_FLAG, PositionDoesNotExist());
                        continue;
                    } else if (positions[i].action == Actions.BURN_POSITION) {
                        uint256 position = idsSlot.positions[positions[i].tokenId];
                        uint256 idIndex = position - 1;
                        uint256 lastIndex = idsSlot.tokenIds.length - 1;

                        if (idIndex != lastIndex) {
                            idsSlot.tokenIds[idIndex] = lastIndex;
                            idsSlot.positions[lastIndex] = position;
                        }

                        idsSlot.positions[positions[i].tokenId] = 0;
                        idsSlot.tokenIds.pop();

                        // remove application in proxy persistent storage. Application must be active after first position mint.
                        if (lastIndex == 0) {
                            // remove uniV4 liquidity application
                            StorageLib.activeApplications().removeApplication(uint256(Applications.UNIV4_LIQUIDITY));
                        }
                        continue;
                    } else {
                        // Actions.DECREASE_LIQUIDITY
                        continue;
                    }
                }
            }
        }
    }

    /// @dev We allow the recipient to be the router address, i.e. for unwrap weth. If balance is not swept, it could be stolen.
    /// @dev Passing ROUTER_AS_RECIPIENT is required for payment calls that require the router to hold the balance.
    function _processRecipients(address[] memory recipients) private view {
        for (uint256 i = 0; i < recipients.length; i++) {
            require(
                recipients[i] == address(this) ||
                    recipients[i] == ActionConstants.MSG_SENDER ||
                    recipients[i] == ActionConstants.ADDRESS_THIS,
                RecipientNotSmartPoolOrRouter()
            );
        }
    }

    function _containsMintAction(Position[] memory positions) private pure returns (bool isMint) {
        for (uint i = 0; i < positions.length; i++) {
            if (positions[i].action == Actions.MINT_POSITION) {
                isMint = true;
                break;
            }
        }
    }
}
