// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external;
}

interface IWETH9 {
    function deposit() external payable;
}

/// @notice Mock Across SpokePool for testing
contract MockAcrossSpokePool {
    event V3FundsDeposited(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address depositor,
        address recipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        address exclusiveRelayer,
        bytes message
    );

    address public wrappedNativeToken;
    uint32 public immutable fillDeadlineBuffer;

    constructor(address _wrappedNativeToken) {
        wrappedNativeToken = _wrappedNativeToken;
        fillDeadlineBuffer = 21600;
    }

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
    ) external payable {
        // inputToken should never be address(0) - ETH deposits use WETH address
        require(inputToken != address(0), "Input token cannot be zero address");

        // Only transfer tokens if no native value sent
        // When msg.value > 0, the SpokePool wraps ETH to WETH internally
        if (msg.value == 0) {
            IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        } else {
            IWETH9(wrappedNativeToken).deposit{value: msg.value}();
        }

        emit V3FundsDeposited(
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            depositor,
            recipient,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            exclusiveRelayer,
            message
        );
    }

    // TODO: WTH is this method? what's its use??? just to fake test results?
    /// @notice Mock function to simulate filling a deposit and calling handler
    function simulateFill(address handler, address tokenReceived, uint256 amount, bytes calldata message) external {
        (bool success, ) = handler.call(
            abi.encodeWithSignature("handleV3AcrossMessage(address,uint256,bytes)", tokenReceived, amount, message)
        );
        require(success, "Handler call failed");
    }
}
