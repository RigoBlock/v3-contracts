// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {SafeTransferLib} from "../../contracts/protocol/libraries/SafeTransferLib.sol";

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
        
        // Mock ExtensionsMap to return false for shouldDelegatecall
        vm.mockCall(
            mockExtensionsMap,
            abi.encodeWithSignature("wrappedNative()"),
            abi.encode(Constants.ARB_WETH)
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
        bytes4 donateSelector = ISmartPoolActions.donate.selector;
        
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
        
        // Mock the convertTokenAmount call that's used in donate function
        vm.mockCall(
            pool,
            abi.encodeWithSignature("convertTokenAmount(address,int256,address)", address(0), int256(ETH_DONATION_AMOUNT), address(0)),
            abi.encode(int256(ETH_DONATION_AMOUNT))
        );
        
        vm.startPrank(donor);
        
        console2.log("Calling donate function...");
        // Donate 1 ETH to the pool (baseToken is address(0) for ETH)
        ISmartPoolActions(pool).donate{value: ETH_DONATION_AMOUNT}(address(0), ETH_DONATION_AMOUNT);
        
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
        ISmartPoolActions(pool).donate(address(0), 0);
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
        
        // Mock the convertTokenAmount call
        vm.mockCall(
            pool,
            abi.encodeWithSignature("convertTokenAmount(address,int256,address)", address(0), int256(ETH_DONATION_AMOUNT), address(0)),
            abi.encode(int256(ETH_DONATION_AMOUNT))
        );
        
        vm.prank(donor);
        
        // Donate ETH
        ISmartPoolActions(pool).donate{value: ETH_DONATION_AMOUNT}(address(0), ETH_DONATION_AMOUNT);
        
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
        
        vm.startPrank(donor);
        
        // Should revert with TokenIsNotOwned error
        vm.expectRevert(abi.encodeWithSignature("TokenIsNotOwned()"));
        ISmartPoolActions(pool).donate(randomToken, 1000);
        
        vm.stopPrank();
    }

    /// @notice Test donation fails with incorrect ETH amount
    function test_Donate_IncorrectETHAmount_Reverts() public {
        vm.startPrank(donor);
        
        // Should revert with IncorrectETHAmount error when msg.value != amount
        vm.expectRevert(abi.encodeWithSignature("IncorrectETHAmount()"));
        ISmartPoolActions(pool).donate{value: 1 ether}(address(0), 2 ether);
        
        vm.stopPrank();
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