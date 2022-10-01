// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

contract TestReentrancyAttack {
    address private immutable RIGOBLOCK_POOL;

    constructor(address rigoblockPool) {
        RIGOBLOCK_POOL = rigoblockPool;
    }

    // we send a burn call to rigoblockPool (previously minted on behalf of this pool)
    fallback() external payable {
        _fallback(msg.data);
    }

    // rigoblock pool sends ETH (if ETH-based pool)
    receive() external payable {
        _fallback(_getBurnCallData());
    }

    // we send a new burn request to msg.sender (rigoblock pool)
    function _fallback(bytes memory data) private {
        (, bytes memory returnData) = msg.sender.call(data);
        require(returnData.length != 0, "TEST_REENTRANCY_ATTACK_FAILED_ERROR");
    }

    // encodes IPool.burn(uint256 amount, uint256 minimumAmount)
    function _getBurnCallData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(bytes4(keccak256(bytes("burn(uint256, uint256)"))), 1e18, 1);
    }
}