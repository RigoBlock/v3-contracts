// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {GovernanceActionLib} from "../../contracts/governance/libraries/GovernanceActionLib.sol";
import {ProposedAction} from "../../contracts/governance/types/GovernanceTypes.sol";

/// @title GovernanceActionLib memory-safety tests.
/// @dev A target's return data must never be written into the caller's memory: the library only
///      copies return data when propagating a revert.
contract GovernanceActionLibTest is Test {
    function test_Execute_LargeReturnData_DoesNotCorruptCallerMemory() public {
        ActionLibHarness harness = new ActionLibHarness();
        ReturnBomb bomb = new ReturnBomb();
        ProposedAction memory action = ProposedAction({target: address(bomb), data: "", value: 0});
        harness.executeIsolated(action);
    }

    function test_Execute_LargeReturnData_SubsequentActionDispatchesIntact() public {
        ActionLibHarness harness = new ActionLibHarness();
        ReturnBomb bomb = new ReturnBomb();
        Recorder recorder = new Recorder();
        bytes memory expectedData = abi.encodeWithSelector(Recorder.record.selector, uint256(42));
        ProposedAction memory first = ProposedAction({target: address(bomb), data: "", value: 0});
        ProposedAction memory second = ProposedAction({target: address(recorder), data: expectedData, value: 0});
        harness.executePair(first, second);
        assertEq(recorder.calls(), 1);
        assertEq(recorder.lastData(), expectedData);
    }

    function test_Execute_RevertingTarget_BubblesReturnData() public {
        ActionLibHarness harness = new ActionLibHarness();
        bytes memory revertData = abi.encodeWithSelector(ActionLibTargetFailed.selector);
        ProposedAction memory action = ProposedAction({target: address(new Reverter(revertData)), data: "", value: 0});
        vm.expectRevert(revertData);
        harness.executeIsolated(action);
    }
}

error ActionLibMemoryCorrupted();
error ActionLibTargetFailed();

contract ActionLibHarness {
    function executeIsolated(ProposedAction memory action) external {
        bytes memory canary = new bytes(64);
        for (uint256 i = 0; i < 64; i++) {
            canary[i] = 0xCD;
        }
        GovernanceActionLib.execute(action);
        if (canary[0] != 0xCD || canary[63] != 0xCD) {
            revert ActionLibMemoryCorrupted();
        }
    }

    function executePair(ProposedAction memory first, ProposedAction memory second) external {
        GovernanceActionLib.execute(first);
        GovernanceActionLib.execute(second);
    }
}

/// @dev Returns 64KB of return data, far beyond the scratch space and free-memory pointer.
contract ReturnBomb {
    fallback() external payable {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            return(0, 65536)
        }
    }
}

contract Reverter {
    bytes internal _revertData;

    constructor(bytes memory revertData) {
        _revertData = revertData;
    }

    fallback() external payable {
        bytes memory revertData = _revertData;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }
}

contract Recorder {
    uint256 public calls;
    bytes public lastData;

    function record(uint256) external {
        calls++;
        lastData = msg.data;
    }
}
