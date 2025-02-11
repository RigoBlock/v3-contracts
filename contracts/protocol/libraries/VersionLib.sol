// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library VersionLib {
    // Compare versions
    function isVersionHigherOrEqual(string memory givenVersion, string memory requiredVersion) internal pure returns (bool) {
        uint256[3] memory given = parseVersion(givenVersion);
        uint256[3] memory required = parseVersion(requiredVersion);

        // Compare each part
        for (uint256 i = 0; i < 3; i++) {
            if (given[i] < required[i]) {
                return false;
            }
            if (given[i] > required[i]) {
                return true;
            }
        }
        // If all parts are equal, versions are not higher
        return true;
    }

    // Convert version string to an array of numbers
    function parseVersion(string memory _version) private pure returns (uint256[3] memory versionParts) {
        bytes memory b = bytes(_version);
        
        uint256 partIndex = 0;
        uint256 currentNumber = 0;

        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") {
                versionParts[partIndex] = currentNumber;
                partIndex++;
                currentNumber = 0;
            } else {
                currentNumber = currentNumber * 10 + charToUint(b[i]);
            }
        }
        versionParts[partIndex] = currentNumber;
    }

    // Helper function to convert a single character to an integer
    function charToUint(bytes1 char) private pure returns (uint256) {
        uint256 digit = uint256(uint8(char)) - 48;
        require(digit < 10, "Not a digit");
        return digit;
    }
}