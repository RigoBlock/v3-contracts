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

import {WETH9Interface} from "@across/contracts/external/interfaces/WETH9Interface.sol";
import {SpokePoolInterface} from "@across/contracts/interfaces/SpokePoolInterface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";

/// @title AUniswapRouter - Allows interactions with the Uniswap universal router contracts.
/// @notice This contract is used as a bridge between a Rigoblock smart pool contract and the Uniswap universal router.
/// @dev This contract ensures that tokens approvals are set and removed correctly, and that recipient and tokens are validated.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AIntents {
    using SafeERC20 for IERC20;
    using SafeTransferLib for address;

    SpokePoolInterface public immutable acrossSpokePool;

    /// @notice Cross-chain actions require new feat version 
    string private constant _REQUIRED_VERSION = "4.1.0";

    address private immutable _wrappedNative;

    constructor(
        address acrossSpokePoolAddress
    ) {
        acrossSpokePool = SpokePoolInterface(acrossSpokePoolAddress);
        _wrappedNative = acrossSpokePool.wrappedNativeToken();
    }

    struct Call {
        address target;
        bytes callData;
        uint256 value;
    }

    struct Instructions {
        //  Calls that will be attempted.
        Call[] calls;
        // Where the tokens go if any part of the call fails.
        // Leftover tokens are sent here as well if the action succeeds.
        address fallbackRecipient;
    }

    /// @inheritdoc ISmartPoolOwnerActions
    function initiateCrossChainTransfer(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bool isSendNative,
        bool isReceiveNative
    ) external override nonReentrant onlyDelegateCall {
        require(isOwnedToken(inputToken), TokenIsNotOwned());

        Call[] memory calls = new Call[](4);

        // encode destination chain handler actions
        bytes memory poolApproveCalldata = abi.encodeWithSelector(
            IERC20.approve.selector,
            address(this),
            type(uint256).max
        );
        calls[0] = Call({ target: outputToken, callData: poolApproveCalldata, value: 0 });

        // TODO: the amount could be higher? i.e. we should get the correct amount in a custom handler?
        bytes memory poolDonateCalldata = abi.encodeWithSelector(
            ISmartPool.donate.selector,
            outputToken,
            1 // flag for caller balance
        );
        calls[1] = Call({ target: address(this), callData: poolDonateCalldata, value: 0 });

        poolApproveCalldata = abi.encodeWithSelector(
            IERC20.approve.selector,
            address(this),
            0
        );
        calls[2] = Call({ target: outputToken, callData: poolApproveCalldata, value: 0 });

        if (isReceiveNative) {
            // TODO: the amount could be slightly higher, we we'd have wrapped native left
            wrappedWithdrawCalldata = abi.encodeWithSelector(
                IERC20.withdraw.selector,
                outputAmount; // the actual amount could be higher, a custom handler would be required
            );
            calls[3] = Call({ target: _wrappedNative, callData: wrappedWithdrawCalldata, value: 0 });
        }

        Instructions memory instructions = Instructions({
            calls: isReceiveNative ? calls : calls.pop(),
            fallbackRecipient: address(this);
        });

        if (!isSendNative && inputToken != address(0)) {
            _safeApproveToken(inputToken, address(acrossSpokePool));
        } else {
            inputToken = _wrappedNative;
        }

        // across will expect wrapped native address and msg.value > 0 when bridging native currency
        acrossSpokePool.deposit{value: isSendNative ? inputAmount : 0}(
            address(this).toBytes32(), // depositor
            address(acrossSpokePool).toBytes32(), // will use the default handler and execute passed calls
            inputToken.toBytes32(), // inputToken
            outputToken.toBytes32(), //outputToken
            inputAmount,
            outputAmount,
            destinationChainId,
            address(0).toBytes32(), // exclusiveRelayer, anyone can fill as they see it
            block.timestamp, // quoteTimestamp
            block.timestamp + 5 minutes, // fillDeadline // TODO: add fillDeadlineBuffer
            0, // exclusivityParameter
            abi.encode(instructions);// message
        );

        // we write a virtual balance for the token, which neutralizes the impact on the pool nav
        // NOTICE: the performance of the asset stays in the source pool, which is ok if we implement the cross-nav as well
        // the impact is that a big pool transferring to a small pool will result in potentially a big performance on the small
        // pool if the balance is converted, but it would be the same if we crease a base token virtual balance, because it
        // would be generating a big performance on the destination chain, so we should choose the simples model.
        address baseToken = pool().baseToken;
        int256 convertedAmount = IEOracle(address(this)).convertTokenAmount(token, amount.toInt256(), baseToken);
        virtualBalances[inputToken] += baseCurrencyAmount.toInt256();
    }

    // TODO: verify if we should implement with pool as custom handler, as encoding the calls is prob worse
    // than implementing as a extension (where the across spoke will be allowed to call). Also because that is
    // a callback, if say there is a buf in the code, we can deactivate this adapter, and the callback would
    // not be usable (but we must make sure tokens are not moved regardless, because a rogue solver could spoof a call).
    // Also we are forced to make write calls and revert using the multicall handler, while we could simply make assertions.
    // TODO: verify if this call could safely be opened to anyone
    /// @inheritdoc ISmartPoolOwnerActions
    function rebalance(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bool isSendNative,
        bool isReceiveNative
    ) external override nonReentrant onlyDelegateCall {
        // TODO: if we receive wrapped native address from the api, this might revert (when pool does not own it)
        // TODO: _wrappedNative is also accepted, but it should be stored as an active token
        require(isOwnedToken(sourceToken), TokenIsNotOwned());

        if (!isSendNative && inputToken != address(0)) {
            _safeApproveToken(inputToken, address(acrossSpokePool));
        } else {
            inputToken = _wrappedNative;
        }

        Call[] memory calls;

        if (isReceiveNative) {
            // TODO: if we want to withdraw balance amount, we should implement a withdraw method with flag amount (not ideal)
            withdrawCalldata = abi.encodeWithSelector(
                WETHInterface.withdraw.selector,
                outputAmount; // the actual amount might be higher, a custom handler would be required
            );

            calls = new Call[](2);
            calls[0] = Call({ target: _wrappedNative, callData: withdrawCalldata, value: 0 });
            calls[1] = Call({ target: address(this), callData: "", value: outputAmount });
        } else {
            bytes memory transferCalldata = abi.encodeWithSelector(
                IERC20.transfer.selector, // Changed from safeTransfer to match IERC20
                address(this),
                outputAmount // the actual amount might be higher, a custom handler would be required
            );
        }

        // assertCrosschainNavInRange
        // we will use type(int256).max as flag for a pool initialized on both chains but with same nav (i.e. at deploy)
        uint256 initialNav = _initialNav[destinationChainId] != 0;

        // simulate token exit
        virtualBalances[inputToken == _wrappedNative ? address(0) : inputToken] -= inputAmount;

        // update nav in storage for later retrieval
        ISmartPoolActions.updateUnitaryValue();

        // TODO: technically, we could require the initialization to be executed by the operator before, so we know we send
        // less calls to the destination chain handler (but we would still need to read the delta here)
        // TODO: it could be mapped on the destination chain, but we cannot know in advance
        // at initialization we only want to store the initial nav and navDelta on both chains
        if (!isPoolMapped) {
            // TODO: the inputAmount is the reward for initializing the delta, paid to the solver
            // WARNING: the outputAmount could be non-null, and tokens would be sent to the pool, affecting nav
            outputAmount = 0;

            // TODO: verify method permission, as this modifies storage (only the first time)
            storeNavDeltaCalldata = abi.encodeWithSelector(
                ISmartPool.syncInitialNav.selector,
                _getNav(),
                // TODO: we could pass the delta if exists, with amount flags for pool having same price
                // or we could store initial nav on distination chain (so we don't have to worry about inverting sign
                // when going from chain A to B, or from B to A)
                this.chainId
            );

            calls = new Call[](1);
            calls[0] = Call({ target: address(this), callData: storeNavDeltaCalldata, value: 0 });
        } else {
            // TODO: we could still store nav delta, but this will return if already stored on the dest chain
        }

        // TODO: we need to calc nav delta, i.e. we need to calc total assets, sub inputAmount in base token, divide by total supply
        // or we can create a virtual balance here, so the value will only change on the destination chain, and must be equal to
        // nav after transfer +- slippage tolerance (plus initial nav delta) -> meaning we calc nav only on one chain

        // across will expect wrapped native address and msg.value > 0 when bridging native currency
        acrossSpokePool.deposit{value: isSendNative ? inputAmount : 0}(
            address(this).toBytes32(), // depositor
            address(acrossSpokePool).toBytes32(), // will use the default handler and execute passed calls
            inputToken.toBytes32(), // inputToken
            outputToken.toBytes32(), //outputToken
            inputAmount,
            outputAmount,
            destinationChainId,
            address(0).toBytes32(), // exclusiveRelayer, anyone can fill as they see it
            block.timestamp, // quoteTimestamp
            block.timestamp + 5 minutes, // fillDeadline // TODO: add fillDeadlineBuffer
            0, // exclusivityParameter
            abi.encode(instructions);// message
        );
    }

    /// @dev Some tokens only approve up to type(uint96).max, so we check if approval is less than that amount and approve max uint256 otherwise.
    function _safeApproveToken(address inputToken, address target) private {
        // only approve once, permit2 will handle transaction block approval
        if (IERC20(originToken).allowance(address(this), address(permit2)) < type(uint96).max) {
            originToken.safeApprove(address(permit2), type(uint256).max);
        }

        // expiration is set to 0 so that every transaction has an approval valid only for the transaction block
        permit2.approve(tokensIn[i], target, type(uint160).max, 0);
    }
}