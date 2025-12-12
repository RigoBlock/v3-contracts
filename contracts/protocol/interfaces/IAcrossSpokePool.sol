// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title Across Protocol SpokePool Interface
/// @notice Interface for Across Protocol V3 SpokePool contract
/// @dev Used for cross-chain token transfers via Across Protocol
interface IAcrossSpokePool {
    function fillDeadlineBuffer() external view returns (uint32);

    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;
}
