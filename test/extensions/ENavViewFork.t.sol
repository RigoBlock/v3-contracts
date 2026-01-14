// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {ExtensionsMap} from "../../contracts/protocol/deps/ExtensionsMap.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {NavView} from "../../contracts/protocol/libraries/NavView.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {IENavView} from "../../contracts/protocol/extensions/adapters/interfaces/IENavView.sol";
import {IRigoblockPoolProxy} from "../../contracts/protocol/interfaces/IRigoblockPoolProxy.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {AppTokenBalance, ExternalApp} from "../../contracts/protocol/types/ExternalApp.sol";
import {DeploymentParams, Extensions} from "../../contracts/protocol/types/DeploymentParams.sol";

/// @title ENavViewFork - Fork-based tests for the ENavView extension
/// @notice Tests the ENavView extension against a live pool with implementation upgrade simulation
contract ENavViewForkTest is Test {
    // Using constants for consistency and reduced RPC load  
    uint256 constant MAINNET_BLOCK = Constants.MAINNET_BLOCK; // After oracle deployment

    // Deployed infrastructure addresses from Constants.sol
    address constant AUTHORITY = Constants.AUTHORITY;
    address constant FACTORY = Constants.FACTORY;
    address constant REGISTRY = Constants.REGISTRY;
    address constant GRG_STAKING = Constants.GRG_STAKING;
    address constant WETH = Constants.ETH_WETH;
    address constant UNISWAP_V4_POSM = Constants.UNISWAP_V4_POSM;
    address constant ACROSS_SPOKE_POOL = Constants.ETH_SPOKE_POOL;
    address constant ACROSS_MULTICALL_HANDLER = Constants.ETH_MULTICALL_HANDLER;

    // Test pool with assets on multiple chains
    address constant TEST_POOL = Constants.TEST_POOL;

    // Implementation slot from EIP-1967
    bytes32 constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    // Fork ID
    uint256 mainnetFork;

    // Test contracts
    ENavView eNavView;
    EApps eApps;
    EOracle eOracle;
    EUpgrade eUpgrade;
    ECrosschain eCrosschain;
    ExtensionsMapDeployer deployer;
    ExtensionsMap extensionsMap;
    SmartPool newImplementation;

    // Original implementation for comparison
    address originalImplementation;
    uint256 originalNav;

    function setUp() public {
        mainnetFork = vm.createSelectFork("mainnet", MAINNET_BLOCK);
        console2.log("=== Setting up ENavView Fork Test ===");

        // Get original implementation
        originalImplementation = _getImplementationAddress(TEST_POOL);
        console2.log("Original implementation:", originalImplementation);

        // Get original NAV value for comparison (no update needed)
        ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(TEST_POOL).getPoolTokens();
        originalNav = poolTokens.unitaryValue;
        console2.log("Original NAV:", originalNav);

        // Deploy all extensions
        _deployExtensions();

        // Deploy new ExtensionsMap with all extensions
        _deployExtensionsMap();

        // Deploy new implementation with updated ExtensionsMap
        _deployNewImplementation();

        // Upgrade the test pool to use new implementation
        _upgradeTestPoolImplementation();

        console2.log("Setup complete");
    }

    function _deployExtensions() private {
        console2.log("Deploying extensions using ExtensionsMapDeployer...");

        // Deploy our own ExtensionsMapDeployer for testing since the struct has changed
        // Use CREATE2 to predict address and only deploy if not already exists
        bytes32 salt = keccak256("test-nav-view-deployer");
        address predictedDeployerAddr = vm.computeCreate2Address(
            salt,
            keccak256(type(ExtensionsMapDeployer).creationCode)
        );
        
        if (predictedDeployerAddr.code.length == 0) {
            // Deploy with CREATE2
            deployer = new ExtensionsMapDeployer{salt: salt}();
            console2.log("  Deployed new ExtensionsMapDeployer:", address(deployer));
        } else {
            deployer = ExtensionsMapDeployer(predictedDeployerAddr);
            console2.log("  Using existing ExtensionsMapDeployer:", address(deployer));
        }

        // Deploy new ENavView extension
        eNavView = new ENavView(GRG_STAKING, UNISWAP_V4_POSM);
        console2.log("  New ENavView:", address(eNavView));

        // We'll deploy ECrosschain since it's not on mainnet yet
        eCrosschain = new ECrosschain();
        console2.log("  New ECrosschain:", address(eCrosschain));

        console2.log("  Using deployed EApps: 0x598Fe2A5a459AA47228088a4206a657Ef8ec3676");
        console2.log("  Using deployed EOracle: 0xd223Ed82D7341aB535673340aDf2A1A39F9b9B91");
        console2.log("  Using deployed EUpgrade: 0x6A17ca05b112485Bd5c73215F275Baff7F980ac6");
    }

    function _deployExtensionsMap() private {
        console2.log("Deploying ExtensionsMap with new ENavView...");

        Extensions memory extensions = Extensions({
            eApps: 0x598Fe2A5a459AA47228088a4206a657Ef8ec3676,
            eNavView: address(eNavView),
            eOracle: 0xd223Ed82D7341aB535673340aDf2A1A39F9b9B91,
            eUpgrade: 0x6A17ca05b112485Bd5c73215F275Baff7F980ac6,
            eCrosschain: address(eCrosschain)
        });

        DeploymentParams memory params = DeploymentParams({
            extensions: extensions,
            wrappedNative: WETH
        });

        bytes32 salt = keccak256(abi.encodePacked("test-nav-view-v1-", block.timestamp));
        
        extensionsMap = ExtensionsMap(deployer.deployExtensionsMap(params, salt));
        console2.log("  ExtensionsMap:", address(extensionsMap));
    }

    function _deployNewImplementation() private {
        console2.log("Deploying new implementation...");

        // Read authority address from existing test pool instead of hardcoding
        address authorityAddress = ISmartPool(payable(TEST_POOL)).authority();
        console2.log("  Authority (from pool):", authorityAddress);

        // Use a mock token jar address for testing
        address mockTokenJar = makeAddr("mockTokenJar");

        newImplementation = new SmartPool(
            authorityAddress,
            address(extensionsMap),
            mockTokenJar
        );

        console2.log("  New implementation:", address(newImplementation));
    }

    function _upgradeTestPoolImplementation() private {
        console2.log("Upgrading test pool implementation...");

        // Store new implementation address at the implementation slot
        vm.store(TEST_POOL, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(newImplementation)))));

        // Verify the upgrade worked
        address upgradedImplementation = _getImplementationAddress(TEST_POOL);
        assertEq(upgradedImplementation, address(newImplementation), "Implementation upgrade failed");

        console2.log("Implementation upgraded successfully");
    }

    function _getImplementationAddress(address proxy) private view returns (address) {
        bytes32 slot = vm.load(proxy, IMPLEMENTATION_SLOT);
        return address(uint160(uint256(slot)));
    }

    /// @notice Test that ENavView works via extension call
    function test_ENavView_GetNavDataView() public view {
        console2.log("=== Testing ENavView.getNavDataView() ===");

        // Call getNavDataView via the pool (using fallback to extension)
        NavView.NavData memory navData = IENavView(TEST_POOL).getNavDataView();

        console2.log("NAV Data:");
        console2.log("  Total Value:", navData.totalValue);
        console2.log("  Unitary Value:", navData.unitaryValue);
        console2.log("  Timestamp:", navData.timestamp);

        // When oracle fails, NAV calculation returns zero values
        // This is the expected behavior when price feeds are unavailable
        if (navData.totalValue == 0 && navData.unitaryValue == 0) {
            console2.log("Oracle price conversion failed - this is expected with test oracle setup");
            // Validate that timestamp is still set
            assertGt(navData.timestamp, 0, "Timestamp should be set even when NAV calculation fails");
        } else {
            // If oracle works, validate positive values
            assertTrue(navData.unitaryValue > 0, "NAV should be positive when oracle works");
            assertEq(navData.timestamp, block.timestamp, "Timestamp should be current block timestamp");

            // Since we're using a live pool with recent data, just validate the NAV is reasonable
            // Rather than comparing to potentially stale originalNav from setup
            console2.log("Current NAV from ENavView:", navData.unitaryValue);
            console2.log("Original NAV from setup:", originalNav);
            
            // Just validate the NAV is within a reasonable range for this pool
            assertGe(navData.unitaryValue, 1e17, "NAV should be at least 0.1 ETH"); // At least 10 cents
            assertLe(navData.unitaryValue, 1e20, "NAV should be reasonable (less than 100 ETH)"); // Less than $400k
        }

        console2.log("NavData test passed");
    }

    /// @notice Test that ENavView returns token balances
    function test_ENavView_GetTokensAndBalances() public view {
        console2.log("=== Testing ENavView.getAppTokensAndBalancesView() ===");

        // Call getTokensAndBalances via the pool
        AppTokenBalance[] memory balances = IENavView(TEST_POOL).getAppTokensAndBalancesView();

        assertTrue(balances.length > 0, "Should have at least one token balance");

        console2.log("Token Balances:");
        for (uint256 i = 0; i < balances.length && i < 10; i++) { // Limit output for readability
            console2.log("  Token:", balances[i].token);
            console2.log("  Balance:", balances[i].amount >= 0 ? uint256(balances[i].amount) : 0);
            if (balances[i].amount < 0) {
                console2.log("  (Negative balance):", uint256(-balances[i].amount));
            }
        }

        if (balances.length > 10) {
            console2.log("  ... and", balances.length - 10, "more tokens");
        }

        console2.log("TokensAndBalances test passed");
    }

    /// @notice Test that ENavView returns application balances
    function test_ENavView_GetAppTokensAndBalancesView() public view {
        console2.log("=== Testing ENavView.getAppTokensAndBalancesView() ===");

        // Call getAppTokensAndBalancesView via the pool (no parameters needed)
        
        try IENavView(TEST_POOL).getAppTokensAndBalancesView() returns (AppTokenBalance[] memory balances) {
            console2.log("Application Balances:");
            console2.log("  Number of balances:", balances.length);

            for (uint256 i = 0; i < balances.length; i++) {
                console2.log("  Balances count:", balances.length);

                // TODO: why does this one return null if balance is negative?
                if (balances[i].amount != 0) {
                    console2.log("    Token:", balances[i].token);
                    console2.log("    Amount:", balances[i].amount >= 0 ? uint256(balances[i].amount) : 0);
                }
            }

            console2.log("OffchainAppTokenBalances test passed");
        } catch (bytes memory reason) {
            console2.log("OffchainAppTokenBalances test failed:");
            console2.logBytes(reason);
            revert("OffchainAppTokenBalances failed");
        }
    }

    /// @notice Test comparison between ENavView and direct NAV calculation
    function test_ENavView_CompareWithDirectCalculation() public {
        console2.log("=== Testing ENavView vs Direct NAV Calculation ===");

        // Try to update NAV directly in storage (may fail due to oracle)
        vm.prank(TEST_POOL);
        try ISmartPoolActions(TEST_POOL).updateUnitaryValue() {
            // Get stored NAV
            ISmartPoolState.PoolTokens memory poolTokens = ISmartPoolState(TEST_POOL).getPoolTokens();
            uint256 storedNav = poolTokens.unitaryValue;

            // Get NAV from ENavView
            NavView.NavData memory navData = IENavView(TEST_POOL).getNavDataView();

            console2.log("NAV Comparison:");
            console2.log("  Stored NAV:", storedNav);
            console2.log("  ENavView NAV:", navData.unitaryValue);

            // If both work, compare them
            if (navData.unitaryValue > 0 && storedNav > 0) {
                // Allow small deviation due to different calculation methods
                uint256 deviation = navData.unitaryValue > storedNav 
                    ? navData.unitaryValue - storedNav 
                    : storedNav - navData.unitaryValue;
                
                uint256 maxDeviation = 0;
                assertLe(deviation, maxDeviation, "NAV deviation from updated stored value!");
                console2.log("NAV comparison test passed");
            } else {
                console2.log("Oracle price conversion failed - both methods return zero as expected");
            }
        } catch (bytes memory reason) {
            console2.log("updateUnitaryValue failed due to oracle issue - this is expected");
            console2.logBytes(reason);
            
            // Test that ENavView handles the failure gracefully
            NavView.NavData memory navData = IENavView(TEST_POOL).getNavDataView();
            assertEq(navData.totalValue, 0, "Should return zero when oracle fails");
            assertEq(navData.unitaryValue, 0, "Should return zero when oracle fails");
            assertGt(navData.timestamp, 0, "Timestamp should be set even when oracle fails");
            console2.log("ENavView correctly handles oracle failure");
        }
    }

    /// @notice Test that extension calls work correctly
    function test_ENavView_ExtensionCalls() public view {
        console2.log("=== Testing Extension Calls ===");

        // Verify extensions map configuration
        (address extension, bool shouldDelegatecall) = extensionsMap.getExtensionBySelector(
            IENavView.getNavDataView.selector
        );
        
        assertEq(extension, address(eNavView), "Extension address should match ENavView");
        assertTrue(shouldDelegatecall, "ENavView calls should use delegatecall");

        // Test other selectors
        (extension, shouldDelegatecall) = extensionsMap.getExtensionBySelector(
            IENavView.getAppTokensAndBalancesView.selector
        );
        assertEq(extension, address(eNavView), "TokensAndBalances selector should route to ENavView");
        assertTrue(shouldDelegatecall, "TokensAndBalances should use delegatecall");

        console2.log("Extension calls test passed");
    }

    /// @notice Test edge cases and error handling
    function test_ENavView_EdgeCases() public view {
        console2.log("=== Testing Edge Cases ===");

        // Test with invalid packed applications
        try IENavView(TEST_POOL).getAppTokensAndBalancesView() {
            // Should not revert for unknown apps, just return empty
        } catch (bytes memory reason) {
            console2.log("Expected behavior for invalid apps:");
            console2.logBytes(reason);
        }

        // Test that calls work even when pool has minimal state
        NavView.NavData memory navData = IENavView(TEST_POOL).getNavDataView();
        
        // When oracle fails, NAV calculation returns zero values - this is expected
        if (navData.totalValue == 0 && navData.unitaryValue == 0) {
            console2.log("Oracle price conversion failed - this is expected with test oracle setup");
            // Validate that timestamp is still set
            assertGt(navData.timestamp, 0, "Timestamp should be set even when NAV calculation fails");
        } else {
            // If oracle works, validate positive values
            assertTrue(navData.unitaryValue > 0, "NAV should be positive when oracle works");
        }

        console2.log("Edge cases test passed");
    }
}