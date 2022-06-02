// SPDX-License-Identifier: Apache 2.0
pragma solidity 0.8.14;

interface IRigoblockV3PoolState {
    function balanceOf(address _who)
        external
        view
        returns (uint256);

    function getEventful()
        external
        view
        returns (address);

    function getData()
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint256 sellPrice,
            uint256 buyPrice
        );

    function calcSharePrice()
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
            uint256 ratio,
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

    function totalSupply()
        external
        view
        returns (uint256);
}