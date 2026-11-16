// SPDX-License-Identifier: Apache 2.0
pragma solidity >=0.8.0 <0.9.0;

import {ExternalApp} from "../../../types/ExternalApp.sol";

interface IEApps {
    /// @notice Returns token balances owned in a set of external contracts.
    /// @param packedApplications The uint encoded bitmap flags of the active applications.
    /// @return appBalances The arrays of lists of token balances grouped by application type.
    function getAppTokenBalances(uint256 packedApplications) external returns (ExternalApp[] memory appBalances);

    /// @notice Returns the pool's Uniswap V4 active liquidity positions.
    /// @return tokenIds Array of liquidity position token ids.
    function getUniV4TokenIds() external view returns (uint256[] memory tokenIds);
}
