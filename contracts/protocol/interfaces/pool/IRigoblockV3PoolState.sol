// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0;

interface IRigoblockV3PoolState {
    /*
     * IMMUTABLE STORAGE
     */
    function AUTHORITY() external view returns (address);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function VERSION() external view returns (string calldata);

    /*
     * VIEW METHODS
     */
    /// @dev Finds details of this pool.
    /// @return poolName String name of this pool.
    /// @return poolSymbol String symbol of this pool.
    /// @return baseToken Address of base token (0 for coinbase).
    /// @return unitaryValue Value of the token in wei unit.
    /// @return spread Value of the spread from unitary value.
    function getData()
        external
        view
        returns (
            string memory poolName,
            string memory poolSymbol,
            address baseToken,
            uint256 unitaryValue,
            uint256 spread
        );

    function getAdminData()
        external
        view
        returns (
            address,
            address feeCollector,
            uint256 transactionFee,
            uint32 minPeriod
        );

    function getKycProvider() external view returns (address);

    function totalSupply() external view returns (uint256);
}
