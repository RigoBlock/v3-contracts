// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

interface IERC721 {
    /// @notice Returns the owner of a given id.
    /// @param tokenId Number of the token id.
    /// @return owner Address of the token owner.
    function ownerOf(uint256 tokenId) external view returns (address owner);
}
