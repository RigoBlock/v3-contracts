// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {NavImpactLib} from "../../contracts/protocol/libraries/NavImpactLib.sol";

/// @title BscPoolUpgradeDebug - Debug fork test verifying stuck BSC pool unblocks after upgrade
/// @notice NOT for CI - local debug only.
contract BscPoolUpgradeDebugTest is Test {
    uint256 constant BSC_BLOCK = 93065000;

    address constant STUCK_POOL = 0xd14d4321a33F7eD001Ba5B60cE54b0F7Ba621247;

    // Current BSC SmartPool constructor args (from deployments/bsc/SmartPool.json)
    address constant BSC_EXTENSIONS_MAP = 0x02d05A307725d91755C486BEafE6697562c9A67A;

    // EIP-1967 implementation slot
    bytes32 constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    uint256 bscFork;

    function setUp() public {
        bscFork = vm.createSelectFork("bnb", BSC_BLOCK);
    }

    /// @notice Verifies updateUnitaryValue() reverts with EffectiveSupplyTooLow on current implementation
    function test_CurrentImpl_UpdateUnitaryValue_Reverts() public {
        int256 vs = int256(uint256(vm.load(STUCK_POOL, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        console2.log("Virtual supply:", vs);

        vm.expectRevert(NavImpactLib.EffectiveSupplyTooLow.selector);
        ISmartPoolActions(STUCK_POOL).updateUnitaryValue();
    }

    /// @notice Verifies updateUnitaryValue() succeeds after upgrading to new implementation
    function test_UpgradedImpl_UpdateUnitaryValue_Succeeds() public {
        // Deploy new implementation reusing existing ExtensionsMap (no extension changes)
        SmartPool newImpl = new SmartPool(Constants.AUTHORITY, BSC_EXTENSIONS_MAP, Constants.TOKEN_JAR);

        // Upgrade via storage slot override
        vm.store(STUCK_POOL, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(newImpl)))));

        // updateUnitaryValue should now succeed
        ISmartPoolActions(STUCK_POOL).updateUnitaryValue();

        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(STUCK_POOL).getPoolTokens();
        console2.log("Total supply:", poolTokens.totalSupply);
        console2.log("Unitary value:", poolTokens.unitaryValue);
        assertGt(poolTokens.unitaryValue, 0, "NAV should be positive after upgrade");
    }
}
