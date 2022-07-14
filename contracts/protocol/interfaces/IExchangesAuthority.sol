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

pragma solidity >=0.8.0 <0.9.0;

/// @title Exchange Authority Interface - A helper contract for the exchange adapters.
/// @author Gabriele Rigo - <gab@rigoblock.com>
// solhint-disable-next-line
interface IExchangesAuthority {

    /*
     * EVENTS
     */
    event AuthoritySet(address indexed authority);
    event WhitelisterSet(address indexed whitelister);
    event WhitelistedAsset(address indexed asset, bool approved);
    event WhitelistedExchange(address indexed exchange, bool approved);
    event WhitelistedWrapper(address indexed wrapper, bool approved);
    event WhitelistedProxy(address indexed proxy, bool approved);
    event WhitelistedMethod(bytes4 indexed method, address indexed exchange, bool approved);
    event NewSigVerifier(address indexed sigVerifier);
    event NewExchangeEventful(address indexed exchangeEventful);
    event NewCasper(address indexed casper);

    /*
     * CORE FUNCTIONS
     */
    /// @dev Allows the owner to whitelist an authority
    /// @param _authority Address of the authority
    /// @param _isWhitelisted Bool whitelisted
    function setAuthority(address _authority, bool _isWhitelisted)
        external;

    /// @dev Allows the owner to whitelist a whitelister
    /// @param _whitelister Address of the whitelister
    /// @param _isWhitelisted Bool whitelisted
    function setWhitelister(address _whitelister, bool _isWhitelisted)
        external;

    /// @dev Allows a whitelister to whitelist an asset
    /// @param _asset Address of the token
    /// @param _isWhitelisted Bool whitelisted
    function whitelistAsset(address _asset, bool _isWhitelisted)
        external;

    /// @dev Allows a whitelister to whitelist an exchange
    /// @param _exchange Address of the target exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistExchange(address _exchange, bool _isWhitelisted)
        external;

    /// @dev Allows a whitelister to whitelist an token wrapper
    /// @param _wrapper Address of the target token wrapper
    /// @param _isWhitelisted Bool whitelisted
    function whitelistWrapper(address _wrapper, bool _isWhitelisted)
        external;

    /// @dev Allows a whitelister to whitelist a tokenTransferProxy
    /// @param _tokenTransferProxy Address of the proxy
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenTransferProxy(
        address _tokenTransferProxy, bool _isWhitelisted)
        external;

    /// @dev Allows a whitelister to enable trading on a particular exchange
    /// @param _asset Address of the token
    /// @param _exchange Address of the exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistAssetOnExchange(
        address _asset,
        address _exchange,
        bool _isWhitelisted)
        external;

    /// @dev Allows a whitelister to enable assiciate wrappers to a token
    /// @param _token Address of the token
    /// @param _wrapper Address of the exchange
    /// @param _isWhitelisted Bool whitelisted
    function whitelistTokenOnWrapper(
        address _token,
        address _wrapper,
        bool _isWhitelisted)
        external;

    /// @dev Allows an admin to whitelist a factory
    /// @param _method Hex of the function ABI
    /// @param _isWhitelisted Bool whitelisted
    function whitelistMethod(
        bytes4 _method,
        address _adapter,
        bool _isWhitelisted)
        external;

    /// @dev Allows the owner to set the signature verifier
    /// @param _sigVerifier Address of the logs contract
    function setSignatureVerifier(address _sigVerifier)
        external;

    /// @dev Allows the owner to set the exchange eventful
    /// @param _exchangeEventful Address of the exchange logs contract
    function setExchangeEventful(address _exchangeEventful)
        external;

    /// @dev Allows the owner to associate an exchange to its adapter
    /// @param _exchange Address of the exchange
    /// @param _adapter Address of the adapter
    function setExchangeAdapter(address _exchange, address _adapter)
        external;

    /// @dev Allows the owner to set the casper contract
    /// @param _casper Address of the casper contract
    function setCasper(address _casper)
        external;

    /*
     * CONSTANT PUBLIC FUNCTIONS
     */
    /// @dev Provides whether an address is an authority
    /// @param _authority Address of the target authority
    /// @return Bool is whitelisted
    function isAuthority(address _authority)
        external view
        returns (bool);

    /// @dev Provides whether an asset is whitelisted
    /// @param _asset Address of the target asset
    /// @return Bool is whitelisted
    function isWhitelistedAsset(address _asset)
        external view
        returns (bool);

    /// @dev Provides whether an exchange is whitelisted
    /// @param _exchange Address of the target exchange
    /// @return Bool is whitelisted
    function isWhitelistedExchange(address _exchange)
        external view
        returns (bool);

    /// @dev Provides whether a token wrapper is whitelisted
    /// @param _wrapper Address of the target exchange
    /// @return Bool is whitelisted
    function isWhitelistedWrapper(address _wrapper)
        external view
        returns (bool);

    /// @dev Provides whether a proxy is whitelisted
    /// @param _tokenTransferProxy Address of the proxy
    /// @return Bool is whitelisted
    function isWhitelistedProxy(address _tokenTransferProxy)
        external view
        returns (bool);

    function getApplicationAdapter(bytes4 _selector)
        external
        view
        returns (address);

    /// @dev Provides the address of the exchange adapter
    /// @param _exchange Address of the exchange
    /// @return Address of the adapter
    function getExchangeAdapter(address _exchange)
        external view
        returns (address);

    /// @dev Provides the address of the signature verifier
    /// @return Address of the verifier
    function getSigVerifier()
        external view
        returns (address);

    /// @dev Checkes whether a token is allowed on an exchange
    /// @param _token Address of the token
    /// @param _exchange Address of the exchange
    /// @return Bool the token is whitelisted on the exchange
    function canTradeTokenOnExchange(address _token, address _exchange)
        external view
        returns (bool);

    /// @dev Checkes whether a token is allowed on a wrapper
    /// @param _token Address of the token
    /// @return Bool the token is whitelisted on the exchange
    function canWrapTokenOnWrapper(address _token, address _wrapper)
        external view
        returns (bool);

    /// @dev Checkes whether a method is allowed on an exchange
    function isMethodAllowed(bytes4 _method, address _exchange)
        external view
        returns (bool);

    /// @dev Checkes whether casper has been inizialized
    /// @return Bool the casper contract has been initialized
    function isCasperInitialized()
        external view
        returns (bool);

    /// @dev Provides the address of the casper contract
    /// @return Address of the casper contract
    function getCasper()
        external view
        returns (address);
}
