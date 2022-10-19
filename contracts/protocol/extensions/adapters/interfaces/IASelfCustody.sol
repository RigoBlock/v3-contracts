// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 RigoBlock, Rigo Intl.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/

// solhint-disable-next-line
pragma solidity >=0.8.0 <0.9.0;

interface IASelfCustody {
    /// @notice Emitted when tokens are transferred to self custody.
    /// @dev Requires minimum GRG active stake. Minimum set by the Rigoblock Dao.
    /// @param from Address of the pool.
    /// @param to Address of the wallet tokens are sent to.
    /// @param token Address of the sent token.
    /// @param amount Number of units of sent token.
    event SelfCustodyTransfer(address indexed from, address indexed to, address indexed token, uint256 amount);

    /// @notice Returns the address of the GRG vault contract.
    /// @return Address of the GRG vault contract.
    function grgVault() external view returns (address);

    /// @notice transfers ETH or tokens to self custody.
    /// @param selfCustodyAccount Address of the target account.
    /// @param token Address of the target token.
    /// @param amount Number of tokens.
    /// @return shortfall Number of GRG pool operator shortfall.
    function transferToSelfCustody(
        address payable selfCustodyAccount,
        address token,
        uint256 amount
    ) external returns (uint256 shortfall);

    /// @notice external check if minimum pool GRG amount requirement satisfied.
    /// @param poolAddress Address of the pool to assert shortfall for.
    /// @return shortfall Number of GRG pool operator shortfall.
    function poolGrgShortfall(address poolAddress) external view returns (uint256);
}
