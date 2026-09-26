// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {GMX_ROUTER, _GMX_READER, _GMX_DATA_STORE, _GMX_ROLE_STORE, _GMX_CHAINLINK_PRICE_FEED} from "../../contracts/protocol/types/GmxConstants.sol";

/// @title GmxDeploymentsConsistencyTest
/// @notice Keeps the hardcoded GMX addresses in GmxConstants.sol in lockstep with GMX's own
///  deployments artifact (lib/gmx-synthetics submodule, deployments/arbitrum/*.json).
/// @dev GMX rotates contract addresses with little notice (v2.2c, ~Sep 15-16 2026, was a
///  3-day notice announced on X while docs and main branch still pointed at the deprecated
///  set). This test fails loudly at CI time when the submodule's deployments JSON diverges
///  from our constants, forcing a deliberate, reviewed address update. Solidity constants
///  cannot be generated from JSON at compile time, so this runtime check is the strongest
///  coupling available. ReferralStorage is intentionally excluded: it predates the
///  gmx-synthetics deployments artifact and is not listed there.
contract GmxDeploymentsConsistencyTest is Test {
    string internal constant DEPLOYMENTS = "lib/gmx-synthetics/deployments/arbitrum/";

    function _deployedAddress(string memory contractName) internal view returns (address) {
        string memory json = vm.readFile(string.concat(DEPLOYMENTS, contractName, ".json"));
        return vm.parseJsonAddress(json, ".address");
    }

    function test_ExchangeRouter_MatchesDeployments() public view {
        assertEq(address(GMX_ROUTER), _deployedAddress("ExchangeRouter"), "GMX_ROUTER mismatch");
    }

    function test_Reader_MatchesDeployments() public view {
        assertEq(_GMX_READER, _deployedAddress("Reader"), "_GMX_READER mismatch");
    }

    function test_DataStore_MatchesDeployments() public view {
        assertEq(_GMX_DATA_STORE, _deployedAddress("DataStore"), "_GMX_DATA_STORE mismatch");
    }

    function test_RoleStore_MatchesDeployments() public view {
        assertEq(_GMX_ROLE_STORE, _deployedAddress("RoleStore"), "_GMX_ROLE_STORE mismatch");
    }

    function test_ChainlinkPriceFeedProvider_MatchesDeployments() public view {
        assertEq(
            _GMX_CHAINLINK_PRICE_FEED,
            _deployedAddress("ChainlinkPriceFeedProvider"),
            "_GMX_CHAINLINK_PRICE_FEED mismatch"
        );
    }
}
