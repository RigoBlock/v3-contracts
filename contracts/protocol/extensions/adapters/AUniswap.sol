// SPDX-License-Identifier: Apache-2.0-or-later
/*

 Copyright 2021-2025 Rigo Intl.

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
pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "../../../utils/exchanges/uniswap/INonfungiblePositionManager/INonfungiblePositionManager.sol";
import {ISwapRouter02} from "../../../utils/exchanges/uniswap/ISwapRouter02/ISwapRouter02.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";
import {EnumerableSet, AddressSet} from "../../libraries/EnumerableSet.sol";
import {StorageLib} from "../../libraries/StorageLib.sol";
import {IAUniswap} from "./interfaces/IAUniswap.sol";
import {IEOracle} from "./interfaces/IEOracle.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";

/// @title AUniswap - Wraps/unwraps native token using uniswapRouter2 selectors.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AUniswap is IAUniswap, IMinimumVersion {
    using EnumerableSet for AddressSet;

    string private constant _REQUIRED_VERSION = "4.0.0";

    address private constant ADDRESS_ZERO = address(0);

    IWETH9 private immutable _weth;

    constructor(address weth) {
        _weth = IWETH9(weth);
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    /// @inheritdoc IAUniswap
    function unwrapWETH9(uint256 amountMinimum) external override {
        _activateToken(ADDRESS_ZERO);
        _weth.withdraw(amountMinimum);
    }

    /// @inheritdoc IAUniswap
    function unwrapWETH9(uint256 amountMinimum, address /*recipient*/) external override {
        _activateToken(ADDRESS_ZERO);
        _weth.withdraw(amountMinimum);
    }

    /// @inheritdoc IAUniswap
    function wrapETH(uint256 value) external override {
        if (value > uint256(0)) {
            _activateToken(address(_weth));
            _weth.deposit{value: value}();
        }
    }

    function _activateToken(address token) private {
        AddressSet storage values = StorageLib.activeTokensSet();

        // update storage with new token
        values.addUnique(IEOracle(address(this)), token, StorageLib.pool().baseToken);
    }
}
