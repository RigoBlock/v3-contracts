// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @notice Mock 0x Deployer/Registry for testing.
/// @dev Simulates ERC721-compatible ownerOf and prev for Settler verification.
contract Mock0xDeployer {
    /// @notice Current Settler address per feature.
    mapping(uint256 => address) public currentSettler;

    /// @notice Previous Settler address per feature (dwell time).
    mapping(uint128 => address) public previousSettler;

    /// @notice Whether a feature is paused (ownerOf reverts).
    mapping(uint256 => bool) public paused;

    function setCurrentSettler(uint256 featureId, address settler) external {
        currentSettler[featureId] = settler;
    }

    function setPreviousSettler(uint128 featureId, address settler) external {
        previousSettler[featureId] = settler;
    }

    function setPaused(uint256 featureId, bool _paused) external {
        paused[featureId] = _paused;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(!paused[tokenId], "Feature paused");
        address settler = currentSettler[tokenId];
        require(settler != address(0), "No settler");
        return settler;
    }

    function prev(uint128 featureId) external view returns (address) {
        address settler = previousSettler[featureId];
        require(settler != address(0), "No previous settler");
        return settler;
    }
}
