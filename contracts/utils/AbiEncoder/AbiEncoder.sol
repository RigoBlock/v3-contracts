// SPDX-License-Identifier: Apache 2.0
/*

 Copyright 2019 RigoBlock.

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

pragma solidity 0.7.4;

/// @title ABI Encoder - return an array of encoded parameters.
/// @author Gabriele Rigo - <gab@rigoblock.com>
abstract contract AbiEncoder {

    struct HandlerMockOrder {
        uint256 orderAmount;
    }

    struct ZeroExOrder {
        address makerAddress;           // Address that created the order.
        address takerAddress;           // Address that is allowed to fill the order. If set to 0, any address is allowed to fill the order.
        address feeRecipientAddress;    // Address that will recieve fees when order is filled.
        address senderAddress;          // Address that is allowed to call Exchange contract methods that affect this order. If set to 0, any address is allowed to call these methods.
        uint256 makerAssetAmount;       // Amount of makerAsset being offered by maker. Must be greater than 0.
        uint256 takerAssetAmount;       // Amount of takerAsset being bid on by maker. Must be greater than 0.
        uint256 makerFee;               // Amount of ZRX paid to feeRecipient by maker when order is filled. If set to 0, no transfer of ZRX from maker to feeRecipient will be attempted.
        uint256 takerFee;               // Amount of ZRX paid to feeRecipient by taker when order is filled. If set to 0, no transfer of ZRX from taker to feeRecipient will be attempted.
        uint256 expirationTimeSeconds;  // Timestamp in seconds at which order expires.
        uint256 salt;                   // Arbitrary number to facilitate uniqueness of the order's hash.
        bytes makerAssetData;           // Encoded data that can be decoded by a specified proxy contract when transferring makerAsset. The last byte references the id of this proxy.
        bytes takerAssetData;           // Encoded data that can be decoded by a specified proxy contract when transferring takerAsset. The last byte references the id of this proxy.
        bytes signature;
    }

    struct TotleOrder {
        address exchangeHandler;
        bytes genericPayload;
    }

    struct TotleTrade {
        bool isSell;
        address tokenAddress;
        uint256 tokenAmount;
        bool optionalTrade;
        uint256 minimumExchangeRate;
        uint256 minimumAcceptableTokenAmount;
        TotleOrder[] orders;
    }

/*
    /// @dev Gets the Abi encoded bytes array of an integer.
    /// @param orderAmount integer of amount.
    /// @return Byte array of the ABI encoded struct.
    function abiEncodeHandlerMockOrder(uint256 orderAmount)
        external
        pure
        returns (bytes memory encodedOrder)
    {
        HandlerMockOrder memory order;
        order.orderAmount = orderAmount;
        encodedOrder = abi.encode(order);
        return encodedOrder;
    }
*/

/*
    // @notice: following structs not supported yet
    // @notice: pragma ABIEncoderV2 prompts stack-too-deep error
    function abiEncodePackedHandlerMockOrder(uint256 orderAmount)
        external
        pure
        returns (bytes memory encodedOrder)
    {
        HandlerMockOrder memory order;
        order.orderAmount = orderAmount;
        encodedOrder = abi.encodePacked(order);
        return encodedOrder;
    }
*/

    function abiEncodeZeroExOrder(
        address makerAddress,
        address takerAddress,
        address feeRecipientAddress,
        address senderAddress,
        uint256 makerAssetAmount,
        uint256 takerAssetAmount,
        uint256 makerFee,
        uint256 takerFee,
        uint256 expirationTimeSeconds,
        // uint256 salt,
        // bytes makerAssetData,
        bytes calldata takerAssetData,
        bytes calldata signature)
        external
        pure
        returns (bytes memory encodedOrder)
    {
        return encodedOrder = abi.encode(
                makerAddress,
                takerAddress,
                feeRecipientAddress,
                senderAddress,
                makerAssetAmount,
                takerAssetAmount,
                makerFee,
                takerFee,
                expirationTimeSeconds,
                //salt,
                //makerAssetData,
                takerAssetData,
                signature
        );
    }
/*
    function abiEncodePackedZeroExOrder(
        address makerAddress,
        address takerAddress,
        address feeRecipientAddress,
        address senderAddress,
        uint256 makerAssetAmount,
        uint256 takerAssetAmount,
        uint256 makerFee,
        uint256 takerFee,
        uint256 expirationTimeSeconds,
        uint256 salt,
        bytes memory makerAssetData,
        bytes memory takerAssetData)
        public
        pure
        returns (bytes memory encodedOrder)
    {
        ZeroExOrder memory order;
        order.makerAddress = makerAddress;
        order.takerAddress = takerAddress;
        order.feeRecipientAddress = feeRecipientAddress;
        order.senderAddress = senderAddress;
        order.makerAssetAmount = makerAssetAmount;
        order.takerAssetAmount = takerAssetAmount;
        order.makerFee = makerFee;
        order.takerFee = takerFee;
        order.expirationTimeSeconds = expirationTimeSeconds;
        order.salt = salt;
        order.makerAssetData = makerAssetData;
        order.takerAssetData = takerAssetData;
        encodedOrder = abi.encodePacked(
            "ZeroExOrder(",
                "address makerAddress,",
                "address takerAddress,",
                "address feeRecipientAddress,",
                "address senderAddress,",
                "uint256 makerAssetAmount,",
                "uint256 takerAssetAmount,",
                "uint256 makerFee,",
                "uint256 takerFee,",
                "uint256 expirationTimeSeconds,",
                "uint256 salt,",
                "bytes makerAssetData,",
                "bytes takerAssetData",
            ")"
        );
        return encodedOrder;
    }

    function abiEncodeTotleOrder(
        address exchangeHandler,
        bytes memory genericPayload)
        public
        pure
        returns (bytes memory encodedOrder)
    {
        TotleOrder memory order;
        order.exchangeHandler = exchangeHandler;
        order.genericPayload = genericPayload;
        encodedOrder = abi.encodePacked(
            "TotleOrder(",
                "address exchangeHandler,",
                "bytes genericPayload,",
            ")"
        );
    }

    function abiEncodePackedTotleOrder(
        address exchangeHandler,
        bytes memory genericPayload)
        public
        pure
        returns (bytes memory encodedOrder)
    {
        TotleOrder memory order;
        order.exchangeHandler = exchangeHandler;
        order.genericPayload = genericPayload;
        encodedOrder = abi.encodePacked(
            "TotleOrder(",
                "address exchangeHandler,",
                "bytes genericPayload,",
            ")"
        );
        return encodedOrder;
    }

    // @notice the following two functions require ABIencoderV2, which is not optimized
    // @notice switch to ABIencoderV2 results in stack-too-deep error
    function abiEncodeTotleTrade(
        bool isSell,
        address tokenAddress,
        uint256 tokenAmount,
        bool optionalTrade,
        uint256 minimumExchangeRate,
        uint256 minimumAcceptableTokenAmount,
        TotleOrder[] memory orders)
        public
        pure
        returns (bytes memory encodedOrder)
    {
        TotleTrade memory order;
        order.isSell = isSell;
        order.tokenAddress = tokenAddress;
        order.tokenAmount = tokenAmount;
        order.optionalTrade = optionalTrade;
        order.minimumExchangeRate = minimumExchangeRate;
        order.minimumAcceptableTokenAmount = minimumAcceptableTokenAmount;
        order.orders = orders;
        encodedOrder = abi.encodePacked(
            "TotleTrade(",
                "bool isSell,",
                "address tokenAddress,",
                "uint256 tokenAmount,",
                "bool optionalTrade,",
                "uint256 minimumExchangeRate,",
                "uint256 minimumAcceptableTokenAmount,",
                "TotleOrder[] orders,",
            ")"
        );
        return encodedOrder;
    }

    function abiEncodePackedTotleTrade(
        bool isSell,
        address tokenAddress,
        uint256 tokenAmount,
        bool optionalTrade,
        uint256 minimumExchangeRate,
        uint256 minimumAcceptableTokenAmount,
        TotleOrder[] memory orders)
        public
        pure
        returns (bytes memory encodedOrder)
    {
        TotleTrade memory order;
        order.isSell = isSell;
        order.tokenAddress = tokenAddress;
        order.tokenAmount = tokenAmount;
        order.optionalTrade = optionalTrade;
        order.minimumExchangeRate = minimumExchangeRate;
        order.minimumAcceptableTokenAmount = minimumAcceptableTokenAmount;
        order.orders = orders;
        encodedOrder = abi.encodePacked(
            "TotleTrade(",
                "bool isSell,",
                "address tokenAddress,",
                "uint256 tokenAmount,",
                "bool optionalTrade,",
                "uint256 minimumExchangeRate,",
                "uint256 minimumAcceptableTokenAmount,",
                "TotleOrder[] orders,",
            ")"
        );
        return encodedOrder;
    }
*/
}
