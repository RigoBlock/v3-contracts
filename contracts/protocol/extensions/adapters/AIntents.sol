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

import {SafeCast} from "@openzeppelin-legacy/contracts/utils/math/SafeCast.sol";
import {IAcrossSpokePool} from "../../interfaces/IAcrossSpokePool.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {ISmartPoolActions} from "../../interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../interfaces/v4/pool/ISmartPoolState.sol";
import {AddressSet, EnumerableSet} from "../../libraries/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "../../libraries/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";
import {SlotDerivation} from "../../libraries/SlotDerivation.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {VirtualBalanceLib} from "../../libraries/VirtualBalanceLib.sol";
import {OpType, DestinationMessage, SourceMessage} from "../../types/Crosschain.sol";
import {EscrowFactory} from "../escrow/EscrowFactory.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IAIntents} from "./interfaces/IAIntents.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

/// @title AIntents - Allows cross-chain token transfers via Across Protocol.
/// @notice This adapter enables Rigoblock smart pools to bridge tokens across chains while maintaining NAV integrity.
/// @dev This contract ensures virtual balances are managed to offset NAV changes from cross-chain transfers.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AIntents is IAIntents, IMinimumVersion, ReentrancyGuardTransient {
    using SafeTransferLib for address;
    using SafeCast for uint256;
    using SafeCast for int256;
    using EnumerableSet for AddressSet;
    using SlotDerivation for bytes32;
    using VirtualBalanceLib for address;

    // Token address constants for better readability
    // Ethereum mainnet
    address private constant ETH_USDC = 0xa0b86a33E6441319A87aA51FBbcFa4De9A7A24c8;
    address private constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant ETH_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Arbitrum
    address private constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address private constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address private constant ARB_WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    // Optimism
    address private constant OPT_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address private constant OPT_USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address private constant OPT_WETH = 0x4200000000000000000000000000000000000006;
    address private constant OPT_WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;

    // Base
    address private constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant BASE_USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address private constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    // Polygon
    address private constant POLY_USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address private constant POLY_USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address private constant POLY_WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address private constant POLY_WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    // BSC
    address private constant BSC_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address private constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address private constant BSC_WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    // Unichain
    address private constant UNI_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant UNI_WETH = 0x4200000000000000000000000000000000000006;

    IAcrossSpokePool public immutable override acrossSpokePool;

    address private immutable _IMPLEMENTATION;

    modifier onlyDelegateCall() {
        require(address(this) != _IMPLEMENTATION, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return "HF_4.1.0";
    }

    constructor(address acrossSpokePoolAddress) {
        acrossSpokePool = IAcrossSpokePool(acrossSpokePoolAddress);
        _IMPLEMENTATION = address(this);
    }

    /// @inheritdoc IAIntents
    function depositV3(AcrossParams calldata params) external override nonReentrant onlyDelegateCall {
        // sanity checks
        // TODO: check if we can safely skip this check. Also maybe use unified error + condition
        require(!params.inputToken.isAddressZero(), NullAddress());
        require(params.exclusiveRelayer.isAddressZero(), NullAddress());

        // Validate bridgeable token restriction - ensure input and output tokens are compatible
        _validateBridgeableTokenPair(params.inputToken, params.outputToken);

        // TODO: validate source message to make sure the params are properly formatted, otherwise we could end up
        // in a scenario where the destination message is not correctly formatted, and the transaction reverts on the
        // dest chain, while it should have reverted on the source chain (i.e. potential loss of funds).
        // { opType, navTolerance, sourceNativeAmount, shouldUnwrapOnDestination }
        SourceMessage memory sourceMsg = abi.decode(params.message, (SourceMessage));

        // TODO: check if we can query tokens + base token in 1 call and reading only exact slots, as we're not writing to storage
        if (params.inputToken != StorageLib.pool().baseToken) {
            require(StorageLib.activeTokensSet().isActive(params.inputToken), TokenNotActive());
        }

        // Process message and get encoded result
        DestinationMessage memory destMsg = _processMessage(
            params.inputToken,
            params.outputToken,
            params.inputAmount,
            sourceMsg
        );
        
        _safeApproveToken(params.inputToken);
        
        _executeDeposit(params, sourceMsg, destMsg);
        
        _safeApproveToken(params.inputToken);
    }
    
    /*
     * INTERNAL METHODS
     */
    /// @dev Executes the depositV3 call to avoid stack too deep issues in main function
    function _executeDeposit(
        AcrossParams calldata params,
        SourceMessage memory sourceMsg,
        DestinationMessage memory destMsg
    ) private {
        acrossSpokePool.depositV3{value: sourceMsg.sourceNativeAmount}(
            sourceMsg.opType == OpType.Transfer 
                ? EscrowFactory.getEscrowAddress(address(this), OpType.Transfer)
                : address(this), // depositor for refunds
            address(this),          // recipient - destination chain recipient (always pool)
            params.inputToken,
            params.outputToken,
            params.inputAmount,
            params.outputAmount,
            params.destinationChainId,
            params.exclusiveRelayer,
            params.quoteTimestamp,
            uint32(block.timestamp + acrossSpokePool.fillDeadlineBuffer()),
            params.exclusivityDeadline,
            abi.encode(destMsg)
        );
    }
    
    function _processMessage(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        SourceMessage memory message
    ) private returns (DestinationMessage memory) {
        // Deploy Transfer escrow if needed
        if (message.opType == OpType.Transfer) {
            // Deploy escrow in delegatecall context (address(this) = pool)
            EscrowFactory.deployEscrowIfNeeded(address(this), OpType.Transfer);
            // Only adjust virtual balance for Transfer operations (NAV neutral)
            _adjustVirtualBalanceForTransfer(inputToken, inputAmount);
        } else if (message.opType == OpType.Sync) {
            // Sync operations don't adjust virtual balance (NAV changes expected)
            // TODO: SECURITY CONCERN - Operator could abuse by declaring Transfer operation
            // on source (uses escrow) but inflating NAV on destination before handler processes.
            // Handler must validate opType matches expected behavior and prevent NAV manipulation.
        } else {
            revert InvalidOpType();
        }

        ISmartPoolActions(address(this)).updateUnitaryValue();

        // Apply BSC decimal conversion for USDC/USDT if needed (both directions)
        inputAmount = _applyBscDecimalConversion(inputToken, outputToken, inputAmount);

        // navTolerance in a client-side input
        return DestinationMessage({
            opType: message.opType,
            sourceChainId: block.chainid,
            sourceNav: ISmartPoolState(address(this)).getPoolTokens().unitaryValue,
            sourceDecimals: StorageLib.pool().decimals,
            navTolerance: message.navTolerance > 1000 ? 1000 : message.navTolerance, // reasonable 10% max tolerance
            shouldUnwrap: message.shouldUnwrapOnDestination,
            sourceAmount: inputAmount  // Decimal-adjusted amount for exact cross-chain offsetting
        });
    }
    
    // TODO: check if should create virtual balance for actual token instead instead of base token
    /// @dev Adjusts virtual balance for Transfer mode only - uses per-token virtual balances.
    /// @dev Only called for Transfer operations to maintain NAV neutrality.
    /// @dev Source adds positive virtual balance, destination subtracts same amount for exact NAV neutrality.
    function _adjustVirtualBalanceForTransfer(address inputToken, uint256 inputAmount) private {
        // Create virtual balance for the actual token being transferred
        // This amount is passed to destination via sourceAmount field for exact offsetting
        VirtualBalanceLib.adjustVirtualBalance(inputToken, inputAmount.toInt256());
    }

    /// @dev Applies BSC decimal conversion for USDC/USDT (18 decimals on BSC vs 6 on other chains)
    /// @param inputToken Source token address  
    /// @param outputToken Destination token address
    /// @param amount Original amount in source chain decimals
    /// @return Normalized amount for exact cross-chain virtual balance offsetting
    function _applyBscDecimalConversion(address inputToken, address outputToken, uint256 amount) private pure returns (uint256) {
        // From BSC (18 decimals) -> normalize to 6 decimals
        if (inputToken == BSC_USDC || inputToken == BSC_USDT) {
            return amount / 1e12;  // Convert 18 decimals to 6 decimals
        }
        
        // To BSC (6 decimals) -> convert to 18 decimals  
        if (outputToken == BSC_USDC || outputToken == BSC_USDT) {
            return amount * 1e12;  // Convert 6 decimals to 18 decimals
        }
        
        // No BSC involved - no conversion needed
        return amount;
    }

    /*
     * INTERNAL METHODS
     */
    /// @dev Approves or revokes token approval. If already approved, revokes; otherwise approves max.
    function _safeApproveToken(address token) private {
        if (token.isAddressZero()) return; // Skip if native currency
        
        // TODO: can this fail silently, and are there side effects?
        if (IERC20(token).allowance(address(this), address(acrossSpokePool)) > 0) {
            // Reset to 0 first for tokens that require it (like USDT)
            token.safeApprove(address(acrossSpokePool), 0);
        } else {
            // Approve max amount
            token.safeApprove(address(acrossSpokePool), type(uint256).max);
        }
    }

    /// @dev Validates bridgeable token pairs using stateless conditional checks
    /// @dev Much more gas efficient than storage mappings - no constructor loops or storage writes
    /// @param inputToken Source token address
    /// @param outputToken Destination token address  
    function _validateBridgeableTokenPair(address inputToken, address outputToken) private pure {
        // Input and output tokens must be different (Across should enforce this too)
        require(inputToken != outputToken, TokenMismatch());
        
        // Check USDC bridgeable tokens (includes BSC with 18vs6 decimal conversion)
        if (inputToken == ETH_USDC || inputToken == ARB_USDC || inputToken == OPT_USDC || 
            inputToken == BASE_USDC || inputToken == POLY_USDC || inputToken == BSC_USDC || inputToken == UNI_USDC) {
            require(outputToken == ETH_USDC || outputToken == ARB_USDC || outputToken == OPT_USDC || 
                    outputToken == BASE_USDC || outputToken == POLY_USDC || outputToken == BSC_USDC || outputToken == UNI_USDC,
                    UnsupportedCrossChainToken());
            return;
        }
        
        // Check USDT bridgeable tokens (includes BSC with 18vs6 decimal conversion)
        if (inputToken == ETH_USDT || inputToken == ARB_USDT || inputToken == OPT_USDT || 
            inputToken == BASE_USDT || inputToken == POLY_USDT || inputToken == BSC_USDT) {
            require(outputToken == ETH_USDT || outputToken == ARB_USDT || outputToken == OPT_USDT || 
                    outputToken == BASE_USDT || outputToken == POLY_USDT || outputToken == BSC_USDT,
                    UnsupportedCrossChainToken());
            return;
        }
        
        // Check WETH bridgeable tokens  
        if (inputToken == ETH_WETH || inputToken == ARB_WETH || inputToken == OPT_WETH || 
            inputToken == BASE_WETH || inputToken == POLY_WETH || inputToken == BSC_WETH || inputToken == UNI_WETH) {
            require(outputToken == ETH_WETH || outputToken == ARB_WETH || outputToken == OPT_WETH || 
                    outputToken == BASE_WETH || outputToken == POLY_WETH || outputToken == BSC_WETH || outputToken == UNI_WETH,
                    UnsupportedCrossChainToken());
            return;
        }
        
        // Check WBTC bridgeable tokens (not available on Base, BSC, Unichain)
        if (inputToken == ETH_WBTC || inputToken == ARB_WBTC || inputToken == OPT_WBTC || inputToken == POLY_WBTC) {
            require(outputToken == ETH_WBTC || outputToken == ARB_WBTC || outputToken == OPT_WBTC || outputToken == POLY_WBTC,
                    UnsupportedCrossChainToken());
            return;
        }
        
        // If we get here, input token is not supported
        revert UnsupportedCrossChainToken();
    }
}
