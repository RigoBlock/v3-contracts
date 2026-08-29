// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Price} from "gmx-synthetics/price/Price.sol";
import {IPriceFeed} from "gmx-synthetics/oracle/IPriceFeed.sol";
import {IGmxChainlinkPriceFeedProvider, GmxValidatedPrice} from "../../utils/exchanges/gmx/IGmxSynthetics.sol";
import {GmxConstants} from "./GmxConstants.sol";

type Feed is bytes32;

/// @dev Hardcoded Chainlink fallback feeds for GMX synthetic index tokens.
///  Each entry is packed as `bytes32(feedAddress << 96 | exponent)`
function getFallbackPriceFeed(address token) pure returns (Feed) {
    uint256 nibble = uint160(token) >> 156;
    bytes32 packed;
    if (nibble < 3) {
        if (token == 0x0315441076FF6d3eA09814a2F90a1f980cF03e9e)
            packed = 0x46306f3795342117721d8ded50fbcf6df2b3cc10000000000000000000000022;
        if (token == 0x13674172E6E44D31d4bE489d5184f3457c40153A)
            packed = 0x8c76e8cab5ef3b410a318ddb82d83ed47d7d2701000000000000000000000028;
        if (token == 0x13983f27Ce9365055a6a553233c49fE28e70103e)
            packed = 0xcca91a477fbf466d676b2056bfdfda94f343a64f000000000000000000000022;
        if (token == 0x197aa2DE1313c7AD50184234490E12409B2a1f95)
            packed = 0x4a85b128ebdafc24d5cb611e161376ffdeceb28900000000000000000000002b;
        if (token == 0x2aAB60E62f05d17e58dEc982870bfAdc7F4e7ADF)
            packed = 0xad57d7c059e2afef2241eb6ef43559f8a409897e000000000000000000000022;
        if (token == 0x2e73bDBee83D91623736D514b0BB41f2afd9C7Fd)
            packed = 0x1b47b4124b9a5094c59710e6b9126e5e32a4fb8e000000000000000000000018;
    } else if (nibble < 7) {
        if (token == 0x3E57D02f9d196873e55727382974b02EdebE6bfd)
            packed = 0x0e278d14b4bf6429ddb0a1b353e2ae8a4e128c93000000000000000000000018;
        if (token == 0x3f8f0dCE4dCE4d0D1d0871941e79CDA82cA50d0B)
            packed = 0xdc49f292ad1bb3dab6c11363d74ed06f38b9bd9c00000000000000000000002c;
        if (token == 0x4b9a2b862E1a30e6E844c991D31Dc6387c9d65D5)
            packed = 0x26dc0763135db2ec0dc4563148ac57eb48ed0bad000000000000000000000022;
        if (token == 0x55e85A147a1029b985384822c0B2262dF8023452)
            packed = 0xcc9742d77622ee9abbf1df03530594f9097bdcb3000000000000000000000022;
        if (token == 0x67ADABbAd211eA9b3B4E2fd0FD165E593De1e983)
            packed = 0x4f861f14246229530a881d32c8d26d78b8c48be6000000000000000000000022;
        if (token == 0x6eAbbaA3278556Dc5b19c034dc26c0eaB60d65B5)
            packed = 0x21082ca28570f0ccfb089465bfaefdc77b00d367000000000000000000000018;
    } else if (nibble < 10) {
        if (token == 0x8F6cCb99d4Fd0B4095915147b5ae3bbDb8075394)
            packed = 0xfeac1a3936514746e70170c0f539e70b23d36f19000000000000000000000022;
        if (token == 0x95c317066CF214b2E6588B2685D949384504F51e)
            packed = 0x47c38c695639ae97a00f57d6d9f5ece1debb033c000000000000000000000022;
        if (token == 0x9759C297fb6C91e252c7292cECa30a509558E5De)
            packed = 0xa0c8611b0cfb31bc8ade3189ae2b982c90d9302f000000000000000000000022;
        if (token == 0x97Ce1F309B949f7FBC4f58c5cb6aa417A5ff8964)
            packed = 0x17d8d87df3e279c737568ab0c5cc3ff750ab763e000000000000000000000022;
        if (token == 0x9c060B2fA953b5f69879a8B7B81f62BFfEF360be)
            packed = 0x0c997958cce7a0403aea7e34d14bbada897b5bb3000000000000000000000018;
        if (token == 0x9c74772b713a1B032aEB173E28683D937E51921c)
            packed = 0x82ba56a2fadf9c14f17d08bc51bda0bdb83a8934000000000000000000000022;
    } else if (nibble < 13) {
        if (token == 0xB2f7cefaeEb08Aa347705ac829a7b8bE2FB560f3)
            packed = 0x0301e5d0a8f7490444ebd1921e3d0f0fe772278600000000000000000000002b;
        if (token == 0xB46A094Bc4B0adBD801E14b9DB95e05E28962764)
            packed = 0x5698690a7b7b84f6aa985ef7690a8a7288fbc9c800000000000000000000002c;
        if (token == 0xB79Eb5BA64A167676694bB41bc1640F95d309a2F)
            packed = 0xe56bea9ff0780d668f92a9ab4ace1d713caa1016000000000000000000000022;
        if (token == 0xBaf07cF91D413C0aCB2b7444B9Bf13b4e03c9D71)
            packed = 0x3a9659c071dd3c37a8b1a2363409a8d41b2feae300000000000000000000002e;
        if (token == 0xC5799ab6E2818fD8d0788dB8D156B0c5db1Bf97b)
            packed = 0x4b13dd76de990db9a2dab58d35c2c02e5e3ae848000000000000000000000022;
        if (token == 0xc5dbD52Ae5a927Cf585B884011d0C7631C9974c6)
            packed = 0x5a0a07cd0e9e4754b3fec4fb1ee1a5babbaa6051000000000000000000000023;
    } else {
        if (token == 0xE6172EecBB07F197F52bb73d74daa0e19C31c4Db)
            packed = 0x569dca98c58d7a89cee87801805a8eaaf2c72b5b000000000000000000000022;
        if (token == 0xEcc5eb985Ddbb8335b175b0A2A1144E4c978F1f6)
            packed = 0x0b2ab7ae5276f6f466f8e62953138b106dd19a63000000000000000000000022;
        if (token == 0xF67b2a901D674B443Fa9f6DB2A689B37c07fD4fE)
            packed = 0x1e48733eeee02468b674b69958b046eb6a0a7d94000000000000000000000022;
    }
    return Feed.wrap(packed);
}

/// @title GmxFallback
/// @notice Hardcoded Chainlink fallback feeds for GMX synthetic index tokens
///  that have a Data Stream feed but no on-chain `priceFeed`.
library GmxFallback {
    /// @dev Reads a hardcoded Chainlink fallback aggregator for tokens GMX prices via Data Streams. The multiplier is computed as
    ///  `10^60 / 10^feedDecimals / 10^tokenDecimals` so that `answer * multiplier / 1e30` yields a GMX 1e30 token-unit price.
    function getFallbackPrice(address token) internal view returns (Price.Props memory price) {
        uint256 packedData = uint256(Feed.unwrap(getFallbackPriceFeed(token)));
        address feed = address(uint160(packedData >> 96));
        uint256 multiplier = 10 ** (packedData & type(uint96).max);

        try IPriceFeed(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0) return price;
            if (updatedAt + GmxConstants._FALLBACK_HEARTBEAT < block.timestamp) return price;

            uint256 scaled = (uint256(answer) * multiplier) / GmxConstants._FLOAT_PRECISION;
            price = Price.Props({min: scaled, max: scaled});
        } catch {}
    }
}
