## [2.0.3](https://github.com/rigoblock/v3-contracts/compare/v2.0.2...v2.0.3) (2025-05-25)


### Bug Fixes

* attach value with uni v4 exact out swap ([4b0b480](https://github.com/rigoblock/v3-contracts/commit/4b0b480aed904f71e51e69784e949b90e6eff2d0))
* remove swap-router-contracts package ([959d630](https://github.com/rigoblock/v3-contracts/commit/959d630cf617f8e21f651ff92a667ab60a3e5bbb))
* staking proxy address constant ([3167b46](https://github.com/rigoblock/v3-contracts/commit/3167b46c7135d90dc434d3c98ad7146df4ba9fad))



## [2.0.2](https://github.com/rigoblock/v3-contracts/compare/v2.0.1...v2.0.2) (2025-05-11)


### Bug Fixes

* extensions map salt ([be60fd4](https://github.com/rigoblock/v3-contracts/commit/be60fd45e2c9401e34da71a2ebcb45c3f10717a2))
* remove unused input param ([e53780d](https://github.com/rigoblock/v3-contracts/commit/e53780da1cf0961181110c14a33269b548a1bb0a))
* unichain wrap/unwrap ([7cc7504](https://github.com/rigoblock/v3-contracts/commit/7cc7504f527cf9032f92b6c2bb6c473625fd9979))



## [2.0.1](https://github.com/rigoblock/v3-contracts/compare/v2.0.0...v2.0.1) (2025-05-08)


### Bug Fixes

* add Foundry to publish-npm job ([4e38840](https://github.com/rigoblock/v3-contracts/commit/4e388408996aecb703a7579d607ce5e0778cf35e))



# [2.0.0](https://github.com/rigoblock/v3-contracts/compare/v1.6.0...v2.0.0) (2025-05-08)


* feat!: V4 Release ([81a2bee](https://github.com/rigoblock/v3-contracts/commit/81a2bee78126efe83bd375fd7ea58e87c20faca0))


### BREAKING CHANGES

* major release with automated nav calculation and universal token access



# [1.6.0](https://github.com/rigoblock/v3-contracts/compare/v1.5.0...v1.6.0) (2025-05-08)


### Bug Fixes

* assert mint recipient ([94700ca](https://github.com/rigoblock/v3-contracts/commit/94700cab140ae0f576d273d3b1165d2c8df5475e))
* AUniswapRouter simplification ([036b4ec](https://github.com/rigoblock/v3-contracts/commit/036b4ecfbb0be0b7f95474fc325d02ea4ab21a3e))
* correctly approve uni router for execute ([1b90628](https://github.com/rigoblock/v3-contracts/commit/1b90628258e2eb77317c3579fe7b0be65cfd4221))
* correctly forward native amount for v4 swaps ([6985e99](https://github.com/rigoblock/v3-contracts/commit/6985e9946d7a6b6511954be9f68858425ea95c26))
* deprecate whitelist extension ([75ae7b5](https://github.com/rigoblock/v3-contracts/commit/75ae7b58c8526716a445c542c34bf2683acaf538))
* initial tests fix ([ef7d3b1](https://github.com/rigoblock/v3-contracts/commit/ef7d3b19c72d2fb2e75d78fbb89cb0523f2a02e3))
* initialize uni swapRouter2 instance instead of address ([e5c83e9](https://github.com/rigoblock/v3-contracts/commit/e5c83e9a35197da008acd41f31bb701dffc9d915))
* minor code fixes ([6130e3c](https://github.com/rigoblock/v3-contracts/commit/6130e3c8d010d3a04a4dc5a4d5074cf80697a01e))
* pragma statements apex ([87d6e56](https://github.com/rigoblock/v3-contracts/commit/87d6e5619ecd2a133f4b4d2c8e378d0a62332de5))
* refactorings and optimizations ([37a3078](https://github.com/rigoblock/v3-contracts/commit/37a30783b2fdc305df6467661574d0d096e062b6))
* registry deploy address ([3c67884](https://github.com/rigoblock/v3-contracts/commit/3c67884fc5a1c624d589b3ba71d26dfb3e3ef7f0))
* remove deprecated contracts ([dd97cee](https://github.com/rigoblock/v3-contracts/commit/dd97cee830900882564bfb2ad27fc496d845b819))
* remove solved TODO comments ([a401881](https://github.com/rigoblock/v3-contracts/commit/a401881a17f0b8707b9ef0b70a66b13d8851dfc1))
* remove spread on mint ([26454ef](https://github.com/rigoblock/v3-contracts/commit/26454ef3b9abbb50efe68bfba82857be9a0275b7))
* require approval target is contract ([6695bff](https://github.com/rigoblock/v3-contracts/commit/6695bfffec029319f08b5331f815074b7cc5c797))
* revert if strategy contract does not implement method ([428bfcb](https://github.com/rigoblock/v3-contracts/commit/428bfcb39e303282e7efae4d949d07469c44924f))
* set default minimum period to 1 days ([2222280](https://github.com/rigoblock/v3-contracts/commit/22222801d2aa3ca6c56bab10a60eecea366f5836))
* uni hook permissions + posm `value` + gas optimizations ([59f2d28](https://github.com/rigoblock/v3-contracts/commit/59f2d28094844645e4e91e16bb00b69204e967e2))
* uni v3 methods visibility ([4908ae6](https://github.com/rigoblock/v3-contracts/commit/4908ae68d2f2217db6072dc3debd27aba6c02c13))
* uniswap universal router recipient ([20974c0](https://github.com/rigoblock/v3-contracts/commit/20974c03401c093a0687aad47b430b0220de1a8e))


### Features

* add apps token balances aggregator ([ae3e214](https://github.com/rigoblock/v3-contracts/commit/ae3e214f824d94c3a27cad51a26cdd6388e2d7dd))
* automated nav initial work ([9ede654](https://github.com/rigoblock/v3-contracts/commit/9ede6540574bed6f80f71eb6d946dd646e8b1e1a))
* burn for tokens ([029ec3c](https://github.com/rigoblock/v3-contracts/commit/029ec3c62391234c08a087610bce4a1536dc1f8c))
* deprecate uni v3 liquidity ([15a5f83](https://github.com/rigoblock/v3-contracts/commit/15a5f83ecbdaa83f904ce9bab7a03a2200227e45))
* extensions logic refactoring ([521f41f](https://github.com/rigoblock/v3-contracts/commit/521f41f6b1643fa1f21ae0fc242d9474a262cc16))
* initial work for uniswap v4 support ([56b8327](https://github.com/rigoblock/v3-contracts/commit/56b8327f264f87df5bf2174d56fdd159f16d6ee8))
* move safe transfer and approve to new SafeTransferLib ([86d9366](https://github.com/rigoblock/v3-contracts/commit/86d9366dffbd6dbc3d48becf56c1cee6ec3f6c2f))
* oracle-based automated nav ([cdcfb2f](https://github.com/rigoblock/v3-contracts/commit/cdcfb2f731db75800d5a1a89aa710c36d4c231b4))
* price feed against chain currency ([c94afcc](https://github.com/rigoblock/v3-contracts/commit/c94afcc588020bba653f98e3b863a230f84b35ff))
* same ExtensionsMap address on all chains ([4448c7d](https://github.com/rigoblock/v3-contracts/commit/4448c7dfdcd8186b4d5af7c3d2a6d6076f2a6258))
* several improvements to uniswap router adapter ([edc8b75](https://github.com/rigoblock/v3-contracts/commit/edc8b7544fabb46a097dade6849a51a6be04afde))
* upgrade uniswap v3 adapter ([b024d80](https://github.com/rigoblock/v3-contracts/commit/b024d806a15c6ae29948ee315a578eed6091363a))
* use minimum version in uniswap v3 adapter ([8c44759](https://github.com/rigoblock/v3-contracts/commit/8c4475928c9b9ab9c971161d98f0d328d7f886a6))
* use transient storage for inputs ([cb90c62](https://github.com/rigoblock/v3-contracts/commit/cb90c6230a31448828f13f4697dc12e5867c576a))



