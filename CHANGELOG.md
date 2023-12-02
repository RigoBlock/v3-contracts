# [1.5.0](https://github.com/rigoblock/v3-contracts/compare/v1.4.2...v1.5.0) (2023-11-25)


### Features

* remove deprecated self custody code ([5cf93f9](https://github.com/rigoblock/v3-contracts/commit/5cf93f919ae8be69b35ae893caf4e62bfae3bc78))



## [1.4.2](https://github.com/rigoblock/v3-contracts/compare/v1.4.1...v1.4.2) (2023-11-11)


### Bug Fixes

* gas optimization on initialization revert ([7a36acd](https://github.com/rigoblock/v3-contracts/commit/7a36acd151c75b6444dae6de0a3c4e348df236e7))
* revert with wrong pool initialization ([5cb1cb8](https://github.com/rigoblock/v3-contracts/commit/5cb1cb84bbe46343d1dc42f00e1be45aeef265bd))
* update version in implementation deployment constants ([f6beeb8](https://github.com/rigoblock/v3-contracts/commit/f6beeb889fd8c334ced6fd15eeed639c3c52edab))


### Reverts

* Revert "chore: fix check pr title workflow" ([911ad15](https://github.com/rigoblock/v3-contracts/commit/911ad158f96ede840cf7f2158e6a4fd6fed98908))



## [1.4.1](https://github.com/rigoblock/v3-contracts/compare/v1.4.0...v1.4.1) (2023-09-09)


### Bug Fixes

* patch uniswap adapter ([96adeb9](https://github.com/rigoblock/v3-contracts/commit/96adeb99a06ccfd100416bfa381eee92d37f49d6))



# [1.4.0](https://github.com/rigoblock/v3-contracts/compare/v1.3.0...v1.4.0) (2023-09-09)


### Bug Fixes

* allow swapping for base token if not whitelisted ([8c77a25](https://github.com/rigoblock/v3-contracts/commit/8c77a257a91e6987c0858d73aa654323e2c7205d))
* assert pool is owner of position it is adding liquidity to ([5e29af0](https://github.com/rigoblock/v3-contracts/commit/5e29af00ae875bf2a857adc488015a43668a7d79))
* correctly retrieve tokenOut in uniswap adapter ([19bbbff](https://github.com/rigoblock/v3-contracts/commit/19bbbff856660f46f38bfe875ada13eee17ed35e))
* correctly retrieve tokens from path in uniswap adapter ([2b804b2](https://github.com/rigoblock/v3-contracts/commit/2b804b2a3efe7c5accec3669aba04ca6277cc666))
* modify visibility of internal method ([7dc1914](https://github.com/rigoblock/v3-contracts/commit/7dc19148ca3e23e5699f1abba3e24ef3d8c6aa44))
* remove implementation of sweep methods ([9f00adb](https://github.com/rigoblock/v3-contracts/commit/9f00adb9b1c23d0f2ed45d3dedfe567379035a15))
* support multi-hop uni v2 swaps ([c2f672b](https://github.com/rigoblock/v3-contracts/commit/c2f672b77f0467e67b394b745feabe1e078d8b64))


### Features

* do not store npm adapter 'params' in memory ([ddf84e3](https://github.com/rigoblock/v3-contracts/commit/ddf84e3c45aac763b841f314ef1f9f69fa2698d6))
* update copy and set approval only if positive amount ([2115d2c](https://github.com/rigoblock/v3-contracts/commit/2115d2cea55d740426d4560aa3c970acf9c50a0e))



# [1.3.0](https://github.com/rigoblock/v3-contracts/compare/v1.2.0...v1.3.0) (2023-02-09)


### Bug Fixes

* allow executing during voting period when qualified ([296cda7](https://github.com/rigoblock/v3-contracts/commit/296cda79c9dd418c4bd6b11cac594a58c66de874))


### Features

* add governance adapter ([99d193a](https://github.com/rigoblock/v3-contracts/commit/99d193a2cc77ff1783689eec8b16eaa59c261b9f))
* add governance adapter interface to pool extended interface ([5c767ce](https://github.com/rigoblock/v3-contracts/commit/5c767ce567f05572a3257ebd5a65ce4e9cb694ce))



