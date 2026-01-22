// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RealDeploymentFixture} from "../fixtures/RealDeploymentFixture.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {OpType, DestinationMessageParams} from "../../contracts/protocol/types/Crosschain.sol";

/// @title VSOnlyModel - Tests for the VS-only cross-chain model
/// @notice Verifies the VS-only model behavior:
///         - Transfer: NAV-neutral on source (negative VS written), positive VS on destination
///         - Sync: NAV-impacting on both chains (no VS adjustments)
///         - Effective supply = totalSupply + virtualSupply (can be negative)
///         - 10% cap: effective supply must be >= 10% of totalSupply when VS < 0
contract VSOnlyModelTest is Test, RealDeploymentFixture {

    // Storage slot for virtual supply (from MixinConstants)
    bytes32 internal constant _VIRTUAL_SUPPLY_SLOT = 
        bytes32(uint256(keccak256("pool.proxy.virtual.supply")) - 1);

    function setUp() public {
        // Deploy fixture with USDC on Ethereum
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_USDC;
        deployFixture(baseTokens);
    }

    /// @notice Test that VS starts at 0
    function test_InitialVS_IsZero() public {
        address poolAddr = ethereum.pool;
        vm.selectFork(mainnetForkId);
        
        int256 vs = _getVirtualSupply(poolAddr);
        assertEq(vs, 0, "Initial virtual supply should be 0");
        console2.log("Initial VS:", vs);
    }

    /// @notice Test that Transfer creates positive VS on destination
    function test_Transfer_CreatesPositiveVS_OnDestination() public {
        address poolAddr = ethereum.pool;
        address usdc = Constants.ETH_USDC;
        uint256 transferAmount = 1000e6;
        
        vm.selectFork(mainnetForkId);
        
        // Simulate receiving a Transfer (creates positive VS)
        address ethMulticallHandler = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        
        DestinationMessageParams memory destParams = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Get initial state
        ISmartPoolActions(poolAddr).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory initialTokens = ISmartPoolState(poolAddr).getPoolTokens();
        uint256 initialNav = initialTokens.unitaryValue;
        int256 initialVS = _getVirtualSupply(poolAddr);
        
        console2.log("=== Transfer to Destination ===");
        console2.log("Initial NAV:", initialNav);
        console2.log("Initial VS:", initialVS);
        
        // Execute donation (simulates bridge receiving tokens)
        deal(usdc, ethMulticallHandler, transferAmount);
        vm.startPrank(ethMulticallHandler);
        IECrosschain(poolAddr).donate(usdc, 1, destParams);
        IERC20(usdc).transfer(poolAddr, transferAmount);
        IECrosschain(poolAddr).donate(usdc, transferAmount, destParams);
        vm.stopPrank();
        
        // Verify VS increased
        int256 finalVS = _getVirtualSupply(poolAddr);
        console2.log("Final VS:", finalVS);
        assertTrue(finalVS > initialVS, "VS should increase after receiving Transfer");
        
        // Verify NAV unchanged (NAV-neutral on destination for Transfer)
        ISmartPoolActions(poolAddr).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory finalTokens = ISmartPoolState(poolAddr).getPoolTokens();
        uint256 finalNav = finalTokens.unitaryValue;
        console2.log("Final NAV:", finalNav);
        
        // NAV should be approximately the same (minor rounding differences allowed)
        assertApproxEqRel(finalNav, initialNav, 0.001e18, "NAV should be unchanged after Transfer receive");
    }

    /// @notice Test that Sync increases NAV on destination (NAV-impacting)
    function test_Sync_IncreasesNAV_OnDestination() public {
        address poolAddr = ethereum.pool;
        address usdc = Constants.ETH_USDC;
        uint256 syncAmount = 1000e6;
        
        vm.selectFork(mainnetForkId);
        
        // Simulate receiving a Sync (no VS adjustment, NAV increases)
        address ethMulticallHandler = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        
        DestinationMessageParams memory destParams = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        // Get initial state
        ISmartPoolActions(poolAddr).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory initialTokens = ISmartPoolState(poolAddr).getPoolTokens();
        uint256 initialNav = initialTokens.unitaryValue;
        int256 initialVS = _getVirtualSupply(poolAddr);
        
        console2.log("=== Sync to Destination ===");
        console2.log("Initial NAV:", initialNav);
        console2.log("Initial VS:", initialVS);
        
        // Execute donation (simulates bridge receiving tokens)
        deal(usdc, ethMulticallHandler, syncAmount);
        vm.startPrank(ethMulticallHandler);
        IECrosschain(poolAddr).donate(usdc, 1, destParams);
        IERC20(usdc).transfer(poolAddr, syncAmount);
        IECrosschain(poolAddr).donate(usdc, syncAmount, destParams);
        vm.stopPrank();
        
        // Verify VS unchanged (Sync doesn't affect VS)
        int256 finalVS = _getVirtualSupply(poolAddr);
        console2.log("Final VS:", finalVS);
        assertEq(finalVS, initialVS, "VS should be unchanged after Sync");
        
        // Verify NAV increased (NAV-impacting)
        ISmartPoolActions(poolAddr).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory finalTokens = ISmartPoolState(poolAddr).getPoolTokens();
        uint256 finalNav = finalTokens.unitaryValue;
        console2.log("Final NAV:", finalNav);
        
        assertTrue(finalNav > initialNav, "NAV should increase after Sync receive");
    }

    /// @notice Test negative VS clears when receiving Transfer back
    function test_NegativeVS_ClearsOnInboundTransfer() public {
        address poolAddr = ethereum.pool;
        address usdc = Constants.ETH_USDC;
        
        vm.selectFork(mainnetForkId);
        
        // Manually set negative VS (simulates prior outbound Transfer)
        int256 negativeVS = -500e6; // 500 shares "sent" to another chain
        vm.store(poolAddr, _VIRTUAL_SUPPLY_SLOT, bytes32(uint256(negativeVS)));
        
        int256 vsBeforeTransfer = _getVirtualSupply(poolAddr);
        console2.log("=== Negative VS Clearing ===");
        console2.log("Initial VS (negative):", vsBeforeTransfer);
        assertEq(vsBeforeTransfer, negativeVS, "VS should be negative");
        
        // Now receive a Transfer back (should clear/reduce negative VS)
        uint256 transferAmount = 1000e6;
        address ethMulticallHandler = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
        
        DestinationMessageParams memory destParams = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        deal(usdc, ethMulticallHandler, transferAmount);
        vm.startPrank(ethMulticallHandler);
        IECrosschain(poolAddr).donate(usdc, 1, destParams);
        IERC20(usdc).transfer(poolAddr, transferAmount);
        IECrosschain(poolAddr).donate(usdc, transferAmount, destParams);
        vm.stopPrank();
        
        int256 vsAfterTransfer = _getVirtualSupply(poolAddr);
        console2.log("Final VS:", vsAfterTransfer);
        
        // VS should be less negative (or positive) after receiving Transfer
        assertTrue(vsAfterTransfer > vsBeforeTransfer, "VS should increase after receiving Transfer");
    }

    /// @notice Test effective supply calculation with negative VS
    function test_EffectiveSupply_WithNegativeVS() public {
        address poolAddr = ethereum.pool;
        
        vm.selectFork(mainnetForkId);
        
        // Get current total supply
        ISmartPoolState.PoolTokens memory tokens = ISmartPoolState(poolAddr).getPoolTokens();
        uint256 totalSupply = tokens.totalSupply;
        console2.log("Total Supply:", totalSupply);
        
        // Set negative VS (less than total supply)
        int256 negativeVS = -int256(totalSupply / 2); // 50% of shares "sent" to another chain
        vm.store(poolAddr, _VIRTUAL_SUPPLY_SLOT, bytes32(uint256(negativeVS)));
        
        console2.log("=== Effective Supply with Negative VS ===");
        console2.log("Negative VS:", negativeVS);
        console2.log("Expected Effective Supply:", int256(totalSupply) + negativeVS);
        
        // NAV update should succeed (effective supply still positive)
        ISmartPoolActions(poolAddr).updateUnitaryValue();
        ISmartPoolState.PoolTokens memory finalTokens = ISmartPoolState(poolAddr).getPoolTokens();
        console2.log("NAV after update:", finalTokens.unitaryValue);
        
        assertTrue(finalTokens.unitaryValue > 0, "NAV should be positive");
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Get virtual supply for a pool
    function _getVirtualSupply(address poolAddr) internal view returns (int256) {
        bytes32 value = vm.load(poolAddr, _VIRTUAL_SUPPLY_SLOT);
        return int256(uint256(value));
    }
}
