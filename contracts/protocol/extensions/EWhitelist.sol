// SPDX-License-Identifier: Apache 2.0

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

    address private immutable AUTHORITY;

    struct WhitelistSlot {
        mapping(address => bool) isWhitelisted;
    }

    modifier onlyAuthorized() {
        _assertCallerIsAuthorized();
        _;
    }

    constructor(address _authority) {
        assert(_EWHITELIST_TOKEN_WHITELIST_SLOT == bytes32(uint256(keccak256("ewhitelist.token.whitelist")) - 1));
        AUTHORITY = _authority;
    }

    /// @inheritdoc IEWhitelist
    function whitelistToken(address _token) public override onlyAuthorized {
        require(_isContract(_token), "EWHITELIST_INPUT_NOT_CONTRACT_ERROR");
        require(!_getWhitelistSlot().isWhitelisted[_token], "EWHITELIST_TOKEN_ALREADY_WHITELISTED_ERROR");
        _getWhitelistSlot().isWhitelisted[_token] = true;
        emit Whitelisted(_token, true);
    }

    /// @inheritdoc IEWhitelist
    function removeToken(address _token) public override onlyAuthorized {
        require(_getWhitelistSlot().isWhitelisted[_token], "EWHITELIST_TOKEN_ALREADY_REMOVED_ERROR");
        delete (_getWhitelistSlot().isWhitelisted[_token]);
        emit Whitelisted(_token, false);
    }

    /// @inheritdoc IEWhitelist
    function batchUpdateTokens(address[] calldata _tokens, bool[] memory _whitelisted) external override {
        for (uint256 i = 0; i < _tokens.length; i++) {
            // if upgrading (to i.e. using an internal method), always assert only authority can call batch method
            _whitelisted[i] == true ? whitelistToken(_tokens[i]) : removeToken(_tokens[i]);
        }
    }

    /// @inheritdoc IEWhitelist
    function isWhitelistedToken(address _token) external view override returns (bool) {
        return _getWhitelistSlot().isWhitelisted[_token];
    }

    /// @inheritdoc IEWhitelist
    function getAuthority() public view override returns (address) {
        return AUTHORITY;
    }

    function _getWhitelistSlot() internal pure returns (WhitelistSlot storage s) {
        assembly {
            s.slot := _EWHITELIST_TOKEN_WHITELIST_SLOT
        }
    }

    function _assertCallerIsAuthorized() private view {
        require(IAuthority(getAuthority()).isWhitelister(msg.sender), "EWHITELIST_CALLER_NOT_WHITELISTER_ERROR");
    }

    function _isContract(address _target) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_target)
        }
        return size > 0;
    }
}
