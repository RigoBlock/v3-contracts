// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ISettlerActions} from "0x-settler/src/ISettlerActions.sol";
import {ISettlerTakerSubmitted} from "0x-settler/src/interfaces/ISettlerTakerSubmitted.sol";

/// @title Settler calldata format canaries for A0xRouter.
/// @notice A0xRouter parses settler calldata at fixed ABI offsets (recipient/buyToken at
///     data[4:68], actions[] offset at data[100:132]) and depends on ISettlerActions
///     selector stability. 0x upgrades deployed settlers independently of the pinned
///     submodule: these tests pin the expected values so a submodule bump that changes
///     them fails loudly and prompts a review of the parsing assumptions. The fork replay
///     tests (A0xRouter*Fork.t.sol) are the authoritative guard that live payloads execute.
contract A0xActionsTest is Test {
    /// @dev execute((address,address,uint256),bytes[],bytes32) — overloaded, expected value
    ///     cross-checked against the replay fixtures and live settler bytecode.
    function test_ExecuteSelector_MatchesProductionSettler() public pure {
        assertEq(ISettlerTakerSubmitted.execute.selector, bytes4(0x1fff991f));
    }

    /// @dev The 4-param POSITIVE_SLIPPAGE dispatched by settlers live on Unichain, Optimism
    ///     and Arbitrum (verified against deployed bytecode). Guards against submodule drift
    ///     from the production settlers.
    function test_POSITIVE_SLIPPAGE_Selector_MatchesProductionSettler() public pure {
        assertEq(ISettlerActions.POSITIVE_SLIPPAGE.selector, bytes4(0x34ee90ca));
    }
}
