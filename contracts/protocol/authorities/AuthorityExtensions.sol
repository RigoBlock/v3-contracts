// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2018 RigoBlock, Rigo Investment Sagl.

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

pragma solidity 0.8.14;

import { OwnedUninitialized as Owned } from "../../utils/owned/OwnedUninitialized.sol";
import { IAuthorityExtensions } from "../interfaces/IAuthorityExtensions.sol";

/// @title AuthorityExtensions - A helper contract for the exchange adapters.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
contract AuthorityExtensions is Owned, IAuthorityExtensions {

    BuildingBlocks public blocks;
    Type public types;

    mapping(address => Account) public accounts;

    struct List {
        address target;
    }

    struct Type {
        string types;
        List[] list;
    }

    struct Group {
        bool whitelister;
        bool exchange;
        bool asset;
        bool authority;
        bool wrapper;
        bool proxy;
    }

    struct Account {
        address account;
        bool authorized;
        mapping(bool => Group) groups; //mapping account to bool authorized to bool group
    }

    struct BuildingBlocks {
        address exchangeEventful;
        address sigVerifier;
        // TODO: remove caspter variable
        address casper;
        mapping(address => bool) initialized;
        mapping(address => address) adapter;
        // Mapping of exchange => method => approved
        mapping(bytes4 => address) adapterBySelector;
        // TODO: only map address to address, and to address 0 to revoke (will save gas)
        mapping(address => mapping(address => bool)) allowedTokens;
        mapping(address => mapping(address => bool)) allowedWrappers;
    }

    /*
     * MODIFIERS
     */
    modifier onlyAdmin {
        require(msg.sender == owner || isWhitelister(msg.sender));
        _;
    }

    modifier onlyWhitelister {
        require(isWhitelister(msg.sender));
        _;
    }

    constructor(address _owner) {
      owner = _owner;
    }

    /*
     * CORE FUNCTIONS
     */
    /// @dev Allows the owner to whitelist an authority
    /// @param _authority Address of the authority
    /// @param _isWhitelisted Bool whitelisted
    function setAuthority(address _authority, bool _isWhitelisted)
        external
        onlyOwner
    {
        setAuthorityInternal(_authority, _isWhitelisted);
    }

    /// @dev Allows the owner to whitelist a whitelister
    /// @param _whitelister Address of the whitelister
    /// @param _isWhitelisted Bool whitelisted
    function setWhitelister(address _whitelister, bool _isWhitelisted)
        external
        onlyOwner
    {
        setWhitelisterInternal(_whitelister, _isWhitelisted);
    }

    /// @dev Allows a whitelister to whitelist an asset
    /// @param _asset Address of the token
    /// @param _isWhitelisted Bool whitelisted
    function whitelistAsset(address _asset, bool _isWhitelisted)
        external
        onlyWhitelister
    {
        accounts[_asset].account = _asset;
        accounts[_asset].authorized = _isWhitelisted;
        accounts[_asset].groups[_isWhitelisted].asset = _isWhitelisted;
        types.list.push(List(_asset));
        emit WhitelistedAsset(_asset, _isWhitelisted);
    }

    /// @dev Allows a whitelister to whitelist an token wrapper
    /// @param _wrapper Address of the target token wrapper
    /// @param _isWhitelisted Bool whitelisted
    function whitelistWrapper(address _wrapper, bool _isWhitelisted)
        external
        onlyWhitelister
    {
        accounts[_wrapper].account = _wrapper;
        accounts[_wrapper].authorized = _isWhitelisted;
        accounts[_wrapper].groups[_isWhitelisted].wrapper = _isWhitelisted;
        types.list.push(List(_wrapper));
        emit WhitelistedWrapper(_wrapper, _isWhitelisted);
    }

    /// @dev Allows a whitelister to whitelist a tokenTransferProxy
    /// @param _tokenTransferProxy Address of the proxy
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenTransferProxy(
        address _tokenTransferProxy,
        bool _isWhitelisted)
        external
        onlyWhitelister
    {
        accounts[_tokenTransferProxy].account = _tokenTransferProxy;
        accounts[_tokenTransferProxy].authorized = _isWhitelisted;
        accounts[_tokenTransferProxy].groups[_isWhitelisted].proxy = _isWhitelisted;
        types.list.push(List(_tokenTransferProxy));
        emit WhitelistedProxy(_tokenTransferProxy, _isWhitelisted);
    }

    /// @dev Allows a whitelister to enable trading on a particular exchange
    /// @param _asset Address of the token
    /// @param _exchange Address of the exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistAssetOnExchange(
        address _asset,
        address _exchange,
        bool _isWhitelisted)
        external
        onlyAdmin
    {
        blocks.allowedTokens[_exchange][_asset] = _isWhitelisted;
        emit WhitelistedAsset(_asset, _isWhitelisted);
    }

    /// @dev Allows a whitelister to enable assiciate wrappers to a token
    /// @param _token Address of the token
    /// @param _wrapper Address of the exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenOnWrapper(address _token, address _wrapper, bool _isWhitelisted)
        external
        onlyAdmin
    {
        blocks.allowedWrappers[_wrapper][_token] = _isWhitelisted;
        emit WhitelistedAsset(_token, _isWhitelisted);
    }

    /// @dev Allows an admin to whitelist a factory.
    /// @param _selector Bytes4 hex of the method interface.
    /// @notice setting _adapter to address(0) will effectively revoke method.
    // TODO controlled by owner or whitelister, check desired permissions
    function whitelistMethod(
        bytes4 _selector,
        address _adapter
    )
        external
        onlyAdmin
    {
        require(
            blocks.adapterBySelector[_selector] == address(0),
            "SELECTOR_EXISTS_ERROR"
        );
        blocks.adapterBySelector[_selector] = _adapter;
        emit WhitelistedMethod(_selector, _adapter);
    }

    /// @dev Allows the owner to set the signature verifier
    /// @param _sigVerifier Address of the verifier contract
    function setSignatureVerifier(address _sigVerifier)
        external
        onlyOwner
    {
        blocks.sigVerifier = _sigVerifier;
        emit NewSigVerifier(blocks.sigVerifier);
    }

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Provides whether an address is an authority
    /// @param _authority Address of the target authority
    /// @return Bool is whitelisted
    function isAuthority(address _authority)
        external view
        returns (bool)
    {
        return accounts[_authority].groups[true].authority;
    }

    /// @dev Provides whether an asset is whitelisted
    /// @param _asset Address of the target asset
    /// @return Bool is whitelisted
    function isWhitelistedAsset(address _asset)
        external view
        returns (bool)
    {
        return accounts[_asset].groups[true].asset;
    }

    /// @dev Provides whether an exchange is whitelisted
    /// @param _exchange Address of the target exchange
    /// @return Bool is whitelisted
    function isWhitelistedExchange(address _exchange)
        external view
        returns (bool)
    {
        return accounts[_exchange].groups[true].exchange;
    }

    /// @dev Provides whether a token wrapper is whitelisted
    /// @param _wrapper Address of the target exchange
    /// @return Bool is whitelisted
    function isWhitelistedWrapper(address _wrapper)
        external view
        returns (bool)
    {
        return accounts[_wrapper].groups[true].wrapper;
    }

    /// @dev Provides whether a proxy is whitelisted
    /// @param _tokenTransferProxy Address of the proxy
    /// @return Bool is whitelisted
    function isWhitelistedProxy(address _tokenTransferProxy)
        external view
        returns (bool)
    {
        return accounts[_tokenTransferProxy].groups[true].proxy;
    }

    function getApplicationAdapter(bytes4 _selector)
        external
        view
        override
        returns (address)
    {
        return blocks.adapterBySelector[_selector];
    }

    /// @dev Provides the address of the signature verifier
    /// @return Address of the verifier
    function getSigVerifier()
        external view
        returns (address)
    {
        return blocks.sigVerifier;
    }

    /// @dev Checkes whether a token is allowed on an exchange
    /// @param _token Address of the token
    /// @param _exchange Address of the exchange
    /// @return Bool the token is whitelisted on the exchange
    function canTradeTokenOnExchange(address _token, address _exchange)
        external view
        returns (bool)
    {
        return blocks.allowedTokens[_exchange][_token];
    }

    /// @dev Checkes whether a token is allowed on a wrapper
    /// @param _token Address of the token
    /// @param _wrapper Address of the token wrapper
    /// @return Bool the token is whitelisted on the exchange
    function canWrapTokenOnWrapper(address _token, address _wrapper)
        external view
        returns (bool)
    {
        return blocks.allowedWrappers[_wrapper][_token];
    }

    /// @dev Checkes whether a method is allowed on an exchange
    /// @param _selector Bytes4 of the function signature
    /// @param _adapter Address of the exchange
    /// @return Bool the method is allowed
    function isMethodAllowed(bytes4 _selector, address _adapter)
        external view
        returns (bool)
    {
        // TODO: could remove adapter address and return only if ! address(0)
        if (blocks.adapterBySelector[_selector] == address(0)) { return false; }
        return (blocks.adapterBySelector[_selector] == _adapter);
    }

    /*
     * INTERNAL FUNCTIONS
     */
    /// @dev Allows to whitelist an authority
    /// @param _authority Address of the authority
    /// @param _isWhitelisted Bool whitelisted
    function setAuthorityInternal(
        address _authority,
        bool _isWhitelisted)
        internal
    {
        accounts[_authority].account = _authority;
        accounts[_authority].authorized = _isWhitelisted;
        accounts[_authority].groups[_isWhitelisted].authority = _isWhitelisted;
        setWhitelisterInternal(_authority, _isWhitelisted);
        types.list.push(List(_authority));
        emit AuthoritySet(_authority);
    }

    /// @dev Allows the owner to whitelist a whitelister
    /// @param _whitelister Address of the whitelister
    /// @param _isWhitelisted Bool whitelisted
    function setWhitelisterInternal(
        address _whitelister,
        bool _isWhitelisted)
        internal
    {
        accounts[_whitelister].account = _whitelister;
        accounts[_whitelister].authorized = _isWhitelisted;
        accounts[_whitelister].groups[_isWhitelisted].whitelister = _isWhitelisted;
        types.list.push(List(_whitelister));
        emit WhitelisterSet(_whitelister);
    }

    /// @dev Provides whether an address is whitelister
    /// @param _whitelister Address of the target whitelister
    /// @return Bool is whitelisted
    function isWhitelister(address _whitelister)
        internal view
        returns (bool)
    {
        return accounts[_whitelister].groups[true].whitelister;
    }
}
