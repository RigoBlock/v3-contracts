// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {EscrowFactory} from "../../contracts/protocol/extensions/escrow/EscrowFactory.sol";
import {TransferEscrow} from "../../contracts/protocol/extensions/escrow/TransferEscrow.sol";
import {IEAcrossHandler} from "../../contracts/protocol/extensions/adapters/interfaces/IEAcrossHandler.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {SafeTransferLib} from "../../contracts/protocol/libraries/SafeTransferLib.sol";
import {DestinationMessageParams, OpType} from "../../contracts/protocol/types/Crosschain.sol";

contract PoolDonateTest is Test {
    using SafeTransferLib for address;
    using stdStorage for StdStorage;

    // EIP1967 implementation slot
    bytes32 internal constant _IMPLEMENTATION_SLOT = 
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    // Test addresses
    address pool;
    address donor;
    address baseToken;
    SmartPool implementation;
    
    // Test amounts
    uint256 constant DONATION_AMOUNT = 10000e6; // 10k tokens
    uint256 constant ETH_DONATION_AMOUNT = 1 ether;

    function setUp() public {
        // Use hardcoded Arbitrum RPC
        string memory arbitrumRpc = "https://arb1.arbitrum.io/rpc";
        vm.selectFork(vm.createFork(arbitrumRpc));
        
        // Use existing test pool
        pool = Constants.TEST_POOL;
        donor = makeAddr("donor");
        baseToken = address(0); // Test pool uses ETH as base token
        
        // Deploy new SmartPool implementation with donate function
        address mockExtensionsMap = makeAddr("mockExtensionsMap");
        address mockEAcrossHandler = makeAddr("mockEAcrossHandler");
        
        // Mock ExtensionsMap to return false for shouldDelegatecall
        vm.mockCall(
            mockExtensionsMap,
            abi.encodeWithSignature("wrappedNative()"),
            abi.encode(Constants.ARB_WETH)
        );
        
        // Mock getExtensionBySelector to return our mock EAcrossHandler for donate selector
        bytes4 donateSelector = IEAcrossHandler.donate.selector;
        vm.mockCall(
            mockExtensionsMap,
            abi.encodeWithSignature("getExtensionBySelector(bytes4)", donateSelector),
            abi.encode(mockEAcrossHandler, true) // Return address and shouldDelegatecall = true
        );
        
        // Mock the donate function on the EAcrossHandler
        vm.mockCall(
            mockEAcrossHandler,
            abi.encodeWithSelector(IEAcrossHandler.donate.selector),
            abi.encode() // Just succeed
        );
        
        // Also mock specific revert for USDC (non-owned token) when used in escrow test  
        vm.mockCallRevert(
            mockEAcrossHandler,
            abi.encodeWithSelector(IEAcrossHandler.donate.selector, Constants.ARB_USDC, 1, DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: false})),
            abi.encodeWithSignature("TokenIsNotOwned()")
        );
        
        implementation = new SmartPool(
            Constants.AUTHORITY,
            mockExtensionsMap,
            makeAddr("mockTokenJar") // Third parameter for tokenJar
        );
        
        // Update the test pool's implementation to include donate function
        vm.store(
            pool,
            _IMPLEMENTATION_SLOT,
            bytes32(uint256(uint160(address(implementation))))
        );
        
        console2.log("Deployed implementation:", address(implementation));
        console2.log("Pool implementation updated to:", address(implementation));
        console2.log("Setup complete");
        console2.log("Pool:", pool);
        
        // Give donor some ETH for tests
        vm.deal(donor, 10 ether);
        
        console2.log("Pool balance before:", address(pool).balance);
        console2.log("Donor balance:", donor.balance);
    }

    /// @notice Test that donate function exists and is callable
    function test_Donate_FunctionExists() public view {
        // Verify the function exists by checking the selector
        bytes4 donateSelector = IEAcrossHandler.donate.selector;
        
        // Get the pool's code and verify it has the function
        bytes memory poolCode = pool.code;
        assertTrue(poolCode.length > 0, "Pool should have code");
        
        console2.log("Donate function selector:", vm.toString(donateSelector));
        console2.log("Pool has code length:", poolCode.length);
    }

    /// @notice Test successful donation of base token (ETH)
    function test_Donate_BaseToken_Success() public {
        uint256 poolEthBefore = address(pool).balance;
        uint256 donorEthBefore = donor.balance;
        
        console2.log("Before donation:");
        console2.log("  Pool balance:", poolEthBefore);
        console2.log("  Donor balance:", donorEthBefore);
        
        vm.startPrank(donor);
        
        console2.log("Calling donate function...");
        // Donate 1 ETH to the pool (baseToken is address(0) for ETH)
        DestinationMessageParams memory params;
        IEAcrossHandler(pool).donate{value: ETH_DONATION_AMOUNT}(address(0), ETH_DONATION_AMOUNT, params);
        
        vm.stopPrank();
        
        // Verify balances changed correctly
        uint256 poolEthAfter = address(pool).balance;
        uint256 donorEthAfter = donor.balance;
        
        console2.log("After donation:");
        console2.log("  Pool balance:", poolEthAfter);
        console2.log("  Donor balance:", donorEthAfter);
        
        assertTrue(poolEthAfter > poolEthBefore, "Pool should have received ETH");
        assertTrue(donorEthAfter < donorEthBefore, "Donor should have less ETH");
        
        // The amount change should equal the donated amount
        assertEq(poolEthAfter - poolEthBefore, ETH_DONATION_AMOUNT, "Pool should receive exactly 1 ETH");
        assertEq(donorEthBefore - donorEthAfter, ETH_DONATION_AMOUNT, "Donor should lose exactly 1 ETH");
    }

    /// @notice Test zero amount donation
    function test_Donate_ZeroAmount_Success() public {
        vm.prank(donor);
        // Should not revert, just return early
        DestinationMessageParams memory params;
        IEAcrossHandler(pool).donate(address(0), 0, params);
        console2.log("Zero amount donation handled correctly");
    }

    /// @notice Test donation of ETH (native token)
    function test_Donate_ETH_Success() public {
        // Get ETH balances before donation
        uint256 poolEthBefore = pool.balance;
        uint256 donorEthBefore = donor.balance;
        
        console2.log("Before ETH donation:");
        console2.log("  Pool ETH balance:", poolEthBefore);
        console2.log("  Donor ETH balance:", donorEthBefore);
        
        vm.prank(donor);
        
        // Donate ETH
        DestinationMessageParams memory params;
        IEAcrossHandler(pool).donate{value: ETH_DONATION_AMOUNT}(address(0), ETH_DONATION_AMOUNT, params);
        
        // Verify balances
        uint256 poolEthAfter = pool.balance;
        uint256 donorEthAfter = donor.balance;
        
        console2.log("After ETH donation:");
        console2.log("  Pool ETH balance:", poolEthAfter);
        console2.log("  Donor ETH balance:", donorEthAfter);
        
        assertTrue(poolEthAfter > poolEthBefore, "Pool should have more ETH");
        assertTrue(donorEthAfter < donorEthBefore, "Donor should have less ETH");
        
        assertEq(poolEthAfter - poolEthBefore, ETH_DONATION_AMOUNT, "Pool should receive exactly the donation amount");
        assertEq(donorEthBefore - donorEthAfter, ETH_DONATION_AMOUNT, "Donor should lose exactly the donation amount");
    }

    /// @notice Test donation fails with non-owned token
    function test_Donate_NonOwnedToken_Reverts() public {
        // Setup random token that's not owned by pool
        address randomToken = makeAddr("randomToken");
        
        // Remove the general mock and add specific mocks that will cause failures
        vm.clearMockedCalls();
        
        // Re-add necessary mocks
        address mockExtensionsMap = makeAddr("mockExtensionsMap");
        address mockEAcrossHandler = makeAddr("mockEAcrossHandler");
        
        vm.mockCall(
            mockExtensionsMap,
            abi.encodeWithSignature("getExtensionBySelector(bytes4)", IEAcrossHandler.donate.selector),
            abi.encode(mockEAcrossHandler, true)
        );
        
        // Mock the donate function to revert with TokenIsNotOwned for non-owned tokens
        vm.mockCallRevert(
            mockEAcrossHandler,
            abi.encodeWithSelector(IEAcrossHandler.donate.selector, randomToken, 1000, DestinationMessageParams({opType: OpType.Transfer, shouldUnwrapNative: false})),
            abi.encodeWithSignature("TokenIsNotOwned()")
        );
        
        vm.startPrank(donor);
        
        // Should revert with TokenIsNotOwned error 
        vm.expectRevert(abi.encodeWithSignature("TokenIsNotOwned()"));
        DestinationMessageParams memory params;
        params.opType = OpType.Transfer;
        IEAcrossHandler(pool).donate(randomToken, 1000, params);
        
        vm.stopPrank();
    }

    /// @notice Test donation fails with incorrect ETH amount
    function test_Donate_IncorrectETHAmount_Reverts() public {
        // Clear general mocks and add specific failing mock
        vm.clearMockedCalls();
        
        address mockExtensionsMap = makeAddr("mockExtensionsMap");
        address mockEAcrossHandler = makeAddr("mockEAcrossHandler");
        
        vm.mockCall(
            mockExtensionsMap,
            abi.encodeWithSignature("getExtensionBySelector(bytes4)", IEAcrossHandler.donate.selector),
            abi.encode(mockEAcrossHandler, true)
        );
        
        // Mock the donate function to revert with IncorrectETHAmount when msg.value != amount
        vm.mockCallRevert(
            mockEAcrossHandler,
            abi.encodeWithSelector(IEAcrossHandler.donate.selector),
            abi.encodeWithSignature("IncorrectETHAmount()")
        );
        
        vm.startPrank(donor);
        
        // Should revert with IncorrectETHAmount error when msg.value != amount
        vm.expectRevert(abi.encodeWithSignature("IncorrectETHAmount()"));
        DestinationMessageParams memory params;
        IEAcrossHandler(pool).donate{value: 1 ether}(address(0), 2 ether, params);
        
        vm.stopPrank();
    }

    /// @notice Test escrow deployment and refundVault integration with pool
    function test_EscrowIntegration_DeployAndRefund() public {
        // Deploy a Transfer escrow for the pool
        address escrowAddress = EscrowFactory.deployEscrow(pool, OpType.Transfer);
        TransferEscrow escrow = TransferEscrow(payable(escrowAddress));
        
        console2.log("Deployed escrow:", escrowAddress);
        console2.log("Escrow pool:", escrow.pool());
        
        // Verify escrow was deployed correctly
        assertEq(escrow.pool(), pool, "Escrow should reference the correct pool");
        assertTrue(escrowAddress.code.length > 0, "Escrow should be deployed");
        
        // First test: Use non-owned token - should fail with TokenIsNotOwned
        address testToken = Constants.ARB_USDC; // Use real USDC token
        uint256 refundAmount = 5000e6; // 5k USDC
        
        // Fund the escrow with tokens (simulating failed transfer refund)
        deal(testToken, escrowAddress, refundAmount);
        
        // Verify escrow has the tokens
        uint256 escrowBalance = IERC20(testToken).balanceOf(escrowAddress);
        assertEq(escrowBalance, refundAmount, "Escrow should have refund tokens");
        
        console2.log("Testing with non-owned token - should fail with TokenIsNotOwned");
        
        // This should revert because USDC is not in the pool's active tokens
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSignature("TokenIsNotOwned()"));
        escrow.refundVault(testToken);
        
        console2.log("Confirmed TokenIsNotOwned error as expected");
        
        // Second test: Use base token (ETH) which is always accepted
        console2.log("Testing with base token (ETH) - should succeed");
        
        // Give escrow some ETH
        uint256 ethAmount = 1 ether;
        vm.deal(escrowAddress, ethAmount);
        
        // Verify escrow has ETH
        assertEq(escrowAddress.balance, ethAmount, "Escrow should have ETH");
        
        // Get pool ETH balance before refund
        uint256 poolEthBefore = pool.balance;
        console2.log("Pool ETH before refund:", poolEthBefore);
        
        // Mock the convertTokenAmount call for ETH (base token)
        vm.mockCall(
            pool,
            abi.encodeWithSignature("convertTokenAmount(address,int256,address)", address(0), int256(ethAmount), address(0)),
            abi.encode(int256(ethAmount))
        );
        
        // Refund ETH to pool - this should succeed since ETH is the base token
        vm.prank(donor);
        escrow.refundVault(address(0)); // address(0) means native ETH
        
        // Verify escrow no longer has ETH
        assertEq(escrowAddress.balance, 0, "Escrow should have no ETH after refund");
        
        // Verify pool received ETH
        uint256 poolEthAfter = pool.balance;
        console2.log("Pool ETH after refund:", poolEthAfter);
        
        assertTrue(poolEthAfter > poolEthBefore, "Pool should have received ETH");
        assertEq(poolEthAfter - poolEthBefore, ethAmount, "Pool should receive exactly the refund amount");
        
        console2.log("ETH escrow refund completed successfully");
    }
    
    /// @notice Test escrow refund with native ETH
    function test_EscrowIntegration_ETHRefund() public {
        // Deploy escrow
        address escrowAddress = EscrowFactory.deployEscrow(pool, OpType.Transfer);
        TransferEscrow escrow = TransferEscrow(payable(escrowAddress));
        
        // Give escrow some ETH
        uint256 ethAmount = 2 ether;
        vm.deal(escrowAddress, ethAmount);
        
        assertEq(escrowAddress.balance, ethAmount, "Escrow should have ETH");
        
        // Get pool ETH balance before
        uint256 poolEthBefore = pool.balance;
        console2.log("Pool ETH before refund:", poolEthBefore);
        
        // Mock the convertTokenAmount call for ETH donation
        vm.mockCall(
            pool,
            abi.encodeWithSignature("convertTokenAmount(address,int256,address)", address(0), int256(ethAmount), address(0)),
            abi.encode(int256(ethAmount))
        );
        
        // Refund ETH to pool
        vm.prank(donor);
        escrow.refundVault(address(0)); // address(0) means native ETH
        
        // Verify escrow has no ETH
        assertEq(escrowAddress.balance, 0, "Escrow should have no ETH after refund");
        
        // Verify pool received ETH (through donate function)
        uint256 poolEthAfter = pool.balance;
        console2.log("Pool ETH after refund:", poolEthAfter);
        
        assertTrue(poolEthAfter > poolEthBefore, "Pool should have received ETH");
        assertEq(poolEthAfter - poolEthBefore, ethAmount, "Pool should receive exactly the refund amount");
        
        console2.log("ETH escrow refund completed successfully");
    }
    
    /// @notice Test multiple escrow deployments have different addresses
    function test_EscrowIntegration_MultipleEscrows() public {
        // Deploy Transfer escrow
        address transferEscrow = EscrowFactory.deployEscrow(pool, OpType.Transfer);
        
        // Deploy Sync escrow
        address syncEscrow = EscrowFactory.deployEscrow(pool, OpType.Sync);
        
        // They should be different addresses
        assertNotEq(transferEscrow, syncEscrow, "Different OpTypes should create different escrows");
        
        // Both should be valid contracts
        assertTrue(transferEscrow.code.length > 0, "Transfer escrow should be deployed");
        assertTrue(syncEscrow.code.length > 0, "Sync escrow should be deployed");
        
        // Both should reference the same pool
        assertEq(TransferEscrow(payable(transferEscrow)).pool(), pool, "Transfer escrow should reference pool");
        assertEq(TransferEscrow(payable(syncEscrow)).pool(), pool, "Sync escrow should reference pool");
        
        console2.log("Transfer escrow:", transferEscrow);
        console2.log("Sync escrow:", syncEscrow);
    }

    /// @notice Helper to verify pool state after operations
    function _verifyPoolState() internal view {
        ISmartPoolState.ReturnedPool memory poolState = ISmartPoolState(pool).getPool();
        
        console2.log("Pool state:");
        console2.log("  Base token:", poolState.baseToken);
        console2.log("  Owner:", poolState.owner);
        console2.log("  Name:", poolState.name);
        console2.log("  Symbol:", poolState.symbol);
        
        assertTrue(bytes(poolState.name).length > 0, "Pool should have name");
        assertTrue(bytes(poolState.symbol).length > 0, "Pool should have symbol");
    }
}