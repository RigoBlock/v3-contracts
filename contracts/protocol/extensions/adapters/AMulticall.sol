// SPDX-License-Identifier: Apache-2.0-or-later

// solhint-disable-next-line
pragma solidity 0.8.14;

import "./interfaces/IAMulticall.sol";

contract AMulticall is IAMulticall {
    /// @inheritdoc IAMulticall
    function multicall(bytes[] calldata data) external override returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                // Next 5 lines from https://ethereum.stackexchange.com/a/83577
                if (result.length < 68) revert();
                assembly {
                    result := add(result, 0x04)
                }
                revert(abi.decode(result, (string)));
            }

            results[i] = result;
        }
    }
}