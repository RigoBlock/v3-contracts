// SPDX-License-Identifier: Apache 2.0

pragma solidity >=0.8.14;

interface INavVerifier {
    /// @dev Verifies that a signature is valid.
    /// @notice Returns true if liquidity at least 3% of total supply.
    /// @param _unitaryValue Value of 1 token in wei units.
    /// @param _signatureValidUntilBlock Number of blocks.
    /// @param _hash Message hash that is signed.
    /// @param _signedData Proof of nav validity.
    /// @return isValid Bool validity of signed data.
    function isValidNav(
        uint256 _unitaryValue,
        uint256 _signatureValidUntilBlock,
        bytes32 _hash,
        bytes calldata _signedData
    ) external view returns (bool isValid);
}