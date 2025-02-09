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

import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {CalldataDecoder} from "@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {ApplicationsLib, ApplicationsSlot} from "../../libraries/ApplicationsLib.sol";
import {EnumerableSet, AddressSet, Pool} from "../../libraries/EnumerableSet.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {Applications, TokenIdsSlot} from "../../types/Applications.sol";
import {IAUniswapRouter, IPositionManager} from "./interfaces/IAUniswapRouter.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {AUniswapDecoder} from "./AUniswapDecoder.sol";

interface IERC721 {
    function ownerOf(uint256 id) external view returns (address owner);
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

    error UniV4PositionsLimitExceeded();

    string public constant override requiredVersion = "4.0.0";

    // transient storage slots
    // bytes32(uint256(keccak256("AUniswapRouter.lock")) - 1)
    bytes32 private constant _LOCK_SLOT = 0x1e2a0e74e761035cb113c1bf11b7fbac06ae91f3a03ce360dda726ba116c216f;
    // bytes32(uint256(keccak256("AUniswapRouter.reentrancy.depth")) - 1)
    bytes32 private constant _REENTRANCY_DEPTH_SLOT =
        0x3921e0fb5d7436d70b7041cccb0d0f543e6b643f41e09aa71450d5e1c5767376;

    // TODO: verify import from common library as EApps uses the same slots
    // persistent storage slots
    bytes32 private constant _POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    bytes32 private constant _TOKEN_REGISTRY_SLOT = 0x3dcde6752c7421366e48f002bbf8d6493462e0e43af349bebb99f0470a12300d;
    bytes32 private constant _APPLICATIONS_SLOT = 0xdc487a67cca3fd0341a90d1b8834103014d2a61e6a212e57883f8680b8f9c831;
    // bytes32(uint256(keccak256("pool.proxy.uniV4.tokenIds")) - 1)
    bytes32 private constant _UNIV4_TOKEN_IDS_SLOT = 0xd87266b00c1e82928c0b0200ad56e2ee648a35d4e9b273d2ac9533471e3b5d3c;

    uint256 private constant NIL_VALUE = 0;

    // TODO: check store as inintiate instances
    address private immutable _uniswapRouter;
    IPositionManager private immutable _positionManager;

    /// @notice Thrown when executing commands with an expired deadline
    error TransactionDeadlinePassed();

    error RecipientIsNotSmartPool();
    error ApprovalFailed(address target);
    error TargetIsNotContract();
    error ReentrantCall();
    error NestedSubPlan();

    // TODO: should verify that it is ok to make direct calls, as they could potentially modify state of the adapter
    // either we make sure that a constructor value prevents setting, or we require delegatecall, which would prevent
    // view methods from msg.sender other than the pool operator.
    constructor(address _universalRouter, address _v4Posm) {
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

    // TODO: same as in constants. Check if can move to library and use from there
    function pool() private pure returns (Pool storage s) {
        assembly {
            s.slot := _POOL_INIT_SLOT
        }
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

    //based on tokens we need to settle, take, we can decide to setApproval or require token price feed
    //(set approval for tokenIn, require price feed for tokenOut, push tokenOut to tracked tokens)
    //potential abuse: token0 amount is null for a non-tracked token, therefore we need to make sure both
    //tokens have a price feed, unless they are already active (which they should be?)

    /// @inheritdoc IAUniswapRouter
    function uniV4Posm() public view override(IAUniswapRouter, AUniswapDecoder) returns (IPositionManager) {
        return _positionManager;
    }

    /// @inheritdoc IAUniswapRouter
    function uniswapRouter() public view override returns (address universalRouter) {
        return _uniswapRouter;
    }

    function uniV4TokenIds() internal pure returns (TokenIdsSlot storage s) {
        assembly {
            s.slot := _UNIV4_TOKEN_IDS_SLOT
        }
    }

    function activeApplications() internal pure returns (ApplicationsSlot storage s) {
        assembly {
            s.slot := _APPLICATIONS_SLOT
        }
    }

    // TODO: by using a shared library, we can avoid type errors
    function activeTokensSet() internal pure returns (AddressSet storage s) {
        assembly {
            s.slot := _TOKEN_REGISTRY_SLOT
        }
    }

    /// @notice An implementation before v4 will be rejected here
    function _assertTokensOutHavePriceFeed(address[] memory tokensOut) private {
        // load active tokens from storage
        AddressSet storage values = activeTokensSet();

        for (uint256 i = 0; i < tokensOut.length; i++) {
            // update storage with new token
            values.addUnique(IEOracle(address(this)), tokensOut[i], pool().baseToken);
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

    function _processTokenIds(int256[] memory tokenIds) private {
        // do not load values unless we are writing to storage
        if (tokenIds.length > 0) {
            // update tokenIds in proxy persistent storage.
            TokenIdsSlot storage idsSlot = uniV4TokenIds();

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

                    if (uniV4Posm().getPositionLiquidity(tokenId) > 0) {
                        // we do not allow delegating liquidity actions on behalf of pool
                        assert(IERC721(address(uniV4Posm())).ownerOf(tokenId) == address(this));
                        continue;
                    } else {
                        // if liquidity is null, we are burning
                        // TODO: should we implement as a library instead?
                        idsSlot.positions[tokenId] = idsSlot.tokenIds[idsSlot.tokenIds.length];
                        idsSlot.tokenIds.pop();
                        continue;
                    }
                }
            }

            // activate/remove application in proxy persistent storage.
            uint256 appsBitmap = activeApplications().packedApplications;
            uint256 appFlag = uint256(Applications.UNIV4_LIQUIDITY);
            bool isActiveApp = ApplicationsLib.isActiveApplication(appsBitmap, appFlag);
            if (uniV4TokenIds().tokenIds.length > 0) {
                require(tokenIds.length < 255, UniV4PositionsLimitExceeded());

                // TODO: pass correct Enum
                // activate uniV4 liquidity application
                if (!isActiveApp) {
                    activeApplications().storeApplication(appFlag);
                }
            } else {
                // remove uniV4 liquidity application
                if (isActiveApp) {
                    activeApplications().removeApplication(appFlag);
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
