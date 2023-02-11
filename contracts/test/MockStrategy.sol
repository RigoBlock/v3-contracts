// SPDX-License-Identifier: Apache 2.0

pragma solidity >0.8.0 <0.9.0;

import "../governance/interfaces/IRigoblockGovernanceFactory.sol";

contract MockStrategy {
    function assertValidInitParams(IRigoblockGovernanceFactory.Parameters memory params) external view {}
}
