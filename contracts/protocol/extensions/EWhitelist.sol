// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2022 Rigo Intl.

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

pragma solidity 0.8.17;

import "./adapters/interfaces/IEWhitelist.sol";
import "../interfaces/IAuthority.sol";
import "../../utils/storageSlot/StorageSlot.sol";

/// @title EWhitelist - Allows whitelisting of tokens.
/// @author Gabriele Rigo - <gab@rigoblock.com>
/// @notice This contract has its own storage, which could potentially clash with pool storage if the allocated slot were already used by the implementation.
/// Warning: careful with upgrades as pool only accesses isWhitelistedToken view method. Other methods are locked and should never be approved by governance.
contract EWhitelist is IEWhitelist {
    bytes32 internal constant _EWHITELIST_TOKEN_WHITELIST_SLOT =
        0x03de6a299bc35b64db5b38a8b5dbbc4bab6e4b5a493067f0fbe40d83350a610f;

    address private immutable authority;

    struct WhitelistSlot {
        mapping(address => bool) isWhitelisted;
    }

    modifier onlyAuthorized() {
        _assertCallerIsAuthorized();
        _;
    }

    constructor(address newAuthority) {
        assert(_EWHITELIST_TOKEN_WHITELIST_SLOT == bytes32(uint256(keccak256("ewhitelist.token.whitelist")) - 1));
        authority = newAuthority;
    }

    /// @inheritdoc IEWhitelist
    function whitelistToken(address token) public override onlyAuthorized {
        require(_isContract(token), "EWHITELIST_INPUT_NOT_CONTRACT_ERROR");
        require(!_getWhitelistSlot().isWhitelisted[token], "EWHITELIST_TOKEN_ALREADY_WHITELISTED_ERROR");
        _getWhitelistSlot().isWhitelisted[token] = true;
        emit Whitelisted(token, true);
    }

    /// @inheritdoc IEWhitelist
    function removeToken(address token) public override onlyAuthorized {
        require(_getWhitelistSlot().isWhitelisted[token], "EWHITELIST_TOKEN_ALREADY_REMOVED_ERROR");
        delete (_getWhitelistSlot().isWhitelisted[token]);
        emit Whitelisted(token, false);
    }

    /// @inheritdoc IEWhitelist
    function batchUpdateTokens(address[] calldata tokens, bool[] memory whitelisted) external override {
        for (uint256 i = 0; i < tokens.length; i++) {
            // if upgrading (to i.e. using an internal method), always assert only authority can call batch method
            whitelisted[i] == true ? whitelistToken(tokens[i]) : removeToken(tokens[i]);
        }
    }

    /// @inheritdoc IEWhitelist
    function isWhitelistedToken(address token) external view override returns (bool) {
        return _getWhitelistSlot().isWhitelisted[token];
    }

    /// @inheritdoc IEWhitelist
    function getAuthority() public view override returns (address) {
        return authority;
    }

    function _getWhitelistSlot() internal pure returns (WhitelistSlot storage s) {
        assembly {
            s.slot := _EWHITELIST_TOKEN_WHITELIST_SLOT
        }
    }

    function _assertCallerIsAuthorized() private view {
        require(IAuthority(getAuthority()).isWhitelister(msg.sender), "EWHITELIST_CALLER_NOT_WHITELISTER_ERROR");
    }

    function _isContract(address target) private view returns (bool) {
        return target.code.length > 0;
    }
}
