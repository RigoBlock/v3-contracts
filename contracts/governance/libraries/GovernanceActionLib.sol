// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {IGovernanceVoting} from "../interfaces/governance/IGovernanceVoting.sol";

library GovernanceActionLib {
    function execute(IGovernanceVoting.ProposedAction memory action) internal {
        address target = action.target;
        uint256 value = action.value;
        bytes memory data = action.data;

        // we revert with error returned from the target
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let didSucceed := call(gas(), target, value, add(data, 0x20), mload(data), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if eq(didSucceed, 0) {
                revert(0, returndatasize())
            }
        }
    }
}
