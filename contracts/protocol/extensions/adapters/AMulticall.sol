// SPDX-License-Identifier: GPL-2.0-or-later

// solhint-disable-next-line
pragma solidity 0.8.37;

import "./interfaces/IAMulticall.sol";
import "./interfaces/IMinimumVersion.sol";

/// @title AMulticall - Allows sending mulple transactions to the pool.
/// @notice As per https://github.com/Uniswap/swap-router-contracts/blob/main/contracts/base/MulticallExtended.sol
contract AMulticall is IAMulticall, IMinimumVersion {
    string private constant _REQUIRED_VERSION = "3.0.0";

    modifier checkDeadline(uint256 deadline) {
        require(_blockTimestamp() <= deadline, MulticallDeadlinePast());
        _;
    }

    modifier checkPreviousBlockhash(bytes32 previousBlockhash) {
        // slither-disable-next-line incorrect-equality -- exact blockhash match is the intended check
        require(blockhash(block.number - 1) == previousBlockhash, MulticallInvalidBlockhash());
        _;
    }

    /// @inheritdoc IAMulticall
    function multicall(bytes[] calldata data) public override returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            // slither-disable-next-line delegatecall-loop -- self-delegatecalls to the pool; msg.value must not be trusted in inner calls
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                // Forward the original revert payload unchanged, preserving custom errors and strings.
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }

            results[i] = result;
        }
    }

    /// @inheritdoc IAMulticall
    function multicall(
        uint256 deadline,
        bytes[] calldata data
    ) external payable override checkDeadline(deadline) returns (bytes[] memory) {
        return multicall(data);
    }

    /// @inheritdoc IAMulticall
    function multicall(
        bytes32 previousBlockhash,
        bytes[] calldata data
    ) external payable override checkPreviousBlockhash(previousBlockhash) returns (bytes[] memory) {
        return multicall(data);
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    /// @dev Method that exists purely to be overridden for tests
    /// @return The current block timestamp
    function _blockTimestamp() internal view virtual returns (uint256) {
        return block.timestamp;
    }
}
