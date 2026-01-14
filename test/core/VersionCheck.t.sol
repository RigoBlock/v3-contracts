// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {VersionLib} from "../../contracts/protocol/libraries/VersionLib.sol";

/// @notice Unit test for VersionLib to cover the missing line 16 (return false case)
/// @dev Directly tests the version comparison logic without proxy/fallback complexity
contract VersionCheckTest is Test {
    using VersionLib for string;

    /// @notice Test that lower major version returns false
    /// @dev This covers VersionLib.sol line 16 (return false path) - major version
    function test_VersionLib_LowerMajorVersion_ReturnsFalse() public {
        console2.log("\n=== Testing Lower Major Version ===");
        
        string memory givenVersion = "4.0.0";
        string memory requiredVersion = "5.0.0";
        
        bool result = givenVersion.isVersionHigherOrEqual(requiredVersion);
        
        console2.log("Given version:", givenVersion);
        console2.log("Required version:", requiredVersion);
        console2.log("Result:", result);
        
        assertFalse(result, "4.0.0 should be lower than 5.0.0");
        console2.log("[PASS] Lower major version correctly returns false");
        console2.log("   This covers VersionLib.sol line 16 (return false path)");
    }

    /// @notice Test that lower minor version returns false
    /// @dev This also covers VersionLib.sol line 16 (return false path) - minor version
    function test_VersionLib_LowerMinorVersion_ReturnsFalse() public {
        console2.log("\n=== Testing Lower Minor Version ===");
        
        string memory givenVersion = "4.0.0";
        string memory requiredVersion = "4.1.0";
        
        bool result = givenVersion.isVersionHigherOrEqual(requiredVersion);
        
        console2.log("Given version:", givenVersion);
        console2.log("Required version:", requiredVersion);
        console2.log("Result:", result);
        
        assertFalse(result, "4.0.0 should be lower than 4.1.0");
        console2.log("[PASS] Lower minor version correctly returns false");
    }

    /// @notice Test that lower patch version returns false
    /// @dev This also covers VersionLib.sol line 16 (return false path) - patch version
    function test_VersionLib_LowerPatchVersion_ReturnsFalse() public {
        console2.log("\n=== Testing Lower Patch Version ===");
        
        string memory givenVersion = "4.0.0";
        string memory requiredVersion = "4.0.1";
        
        bool result = givenVersion.isVersionHigherOrEqual(requiredVersion);
        
        console2.log("Given version:", givenVersion);
        console2.log("Required version:", requiredVersion);
        console2.log("Result:", result);
        
        assertFalse(result, "4.0.0 should be lower than 4.0.1");
        console2.log("[PASS] Lower patch version correctly returns false");
    }

    /// @notice Test that equal versions returns true
    function test_VersionLib_EqualVersions_ReturnsTrue() public {
        console2.log("\n=== Testing Equal Versions ===");
        
        string memory givenVersion = "4.0.0";
        string memory requiredVersion = "4.0.0";
        
        bool result = givenVersion.isVersionHigherOrEqual(requiredVersion);
        
        console2.log("Given version:", givenVersion);
        console2.log("Required version:", requiredVersion);
        console2.log("Result:", result);
        
        assertTrue(result, "4.0.0 should be equal to 4.0.0");
        console2.log("[PASS] Equal versions correctly returns true");
    }

    /// @notice Test that higher version returns true
    function test_VersionLib_HigherVersion_ReturnsTrue() public {
        console2.log("\n=== Testing Higher Version ===");
        
        string memory givenVersion = "5.0.0";
        string memory requiredVersion = "4.0.0";
        
        bool result = givenVersion.isVersionHigherOrEqual(requiredVersion);
        
        console2.log("Given version:", givenVersion);
        console2.log("Required version:", requiredVersion);
        console2.log("Result:", result);
        
        assertTrue(result, "5.0.0 should be higher than 4.0.0");
        console2.log("[PASS] Higher version correctly returns true");
    }

    /// @notice Test edge case with multi-digit versions
    function test_VersionLib_MultiDigitVersions() public {
        console2.log("\n=== Testing Multi-Digit Versions ===");
        
        // Test that 4.10.0 > 4.9.0 (not lexicographic comparison)
        string memory givenVersion = "4.10.0";
        string memory requiredVersion = "4.9.0";
        
        bool result = givenVersion.isVersionHigherOrEqual(requiredVersion);
        
        console2.log("Given version:", givenVersion);
        console2.log("Required version:", requiredVersion);
        console2.log("Result:", result);
        
        assertTrue(result, "4.10.0 should be higher than 4.9.0");
        console2.log("[PASS] Multi-digit versions correctly compared");
    }
}
