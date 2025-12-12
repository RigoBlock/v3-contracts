// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @title MockSpokePool - Mock Across SpokePool for testing
/// @notice Provides minimal implementation for testing Across integration
contract MockSpokePool {
    address public immutable wrappedNativeToken;
    uint32 public immutable fillDeadlineBuffer;
    
    constructor(address _wrappedNativeToken) {
        wrappedNativeToken = _wrappedNativeToken;
        fillDeadlineBuffer = 21600;
    }
    
    /// @notice Mock function to simulate filling a deposit and calling handler
    function simulateFill(
        address handler,
        address tokenReceived,
        uint256 amount,
        bytes calldata message
    ) external {
        (bool success,) = handler.call(
            abi.encodeWithSignature(
                "handleV3AcrossMessage(address,uint256,bytes)",
                tokenReceived,
                amount,
                message
            )
        );
        require(success, "Handler call failed");
    }
}
