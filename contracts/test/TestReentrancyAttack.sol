// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {ISmartPool} from "../protocol/ISmartPool.sol";

contract TestReentrancyAttack {
    address private immutable RIGOBLOCK_POOL;
    uint256 public count = 0;
    uint256 private maxLoopCount = 2;

    constructor(address rigoblockPool) {
        RIGOBLOCK_POOL = rigoblockPool;
    }

    function setMaxCount(uint256 maxCount) external {
        maxLoopCount = maxCount;
    }

    function mintPool() public {
        count += 1;
        if (count <= maxLoopCount) {
            try ISmartPool(payable(RIGOBLOCK_POOL)).mint(address(this), 1e19, 1) {} catch Error(string memory reason) {
                revert(reason);
            }
        }
    }
}
