// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0;

interface IRigoblockV3PoolState {

    /*
     * IMMUTABLE STORAGE
    */
    function AUTHORITY() external view returns (address);

    function decimals() external view returns(uint256);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function VERSION() external view returns (string calldata);

    /*
     * VIEW METHODS
    */
    /// @dev Finds details of this pool.
    /// @return poolName String name of this pool.
    /// @return poolSymbol String symbol of this pool.
    /// @return Value of the token price in wei.
    /// @return Value of the token price in wei.
    function getData()
        external
        view
        returns (
            string memory poolName,
            string memory poolSymbol,
            uint256,    // sellPrice
            uint256     // buyPrice
        );

    function calcTokenPrice()
        external
        view
        returns (uint256);

    function getAdminData()
        external
        view
        returns (
            address,
            address feeCollector,
            address dragoDao,
            uint256, // ratio
            uint256 transactionFee,
            uint32 minPeriod
        );

    function getKycProvider()
        external
        view
        returns (address);

    function isValidSignature(
        bytes32 hash,
        bytes calldata signature
    )
        external
        view
        returns (bool isValid);

    function totalSupply() external view returns (uint256);

    // TODO: not sure correct defining in pool state interface
    // not sure we need this
    function getExtensionsAuthority()
        external
        view
        returns (address);
}
