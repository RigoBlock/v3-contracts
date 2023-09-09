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



# [1.2.0](https://github.com/rigoblock/v3-contracts/compare/v1.1.2...v1.2.0) (2023-02-07)


### Bug Fixes

* first proposal id = 1 ([a747a55](https://github.com/rigoblock/v3-contracts/commit/a747a558e77260b2c3398f53f5db73cea8a0799c))


### Features

* add governance contracts ([36a4eda](https://github.com/rigoblock/v3-contracts/commit/36a4eda8b0440b6971c8de740390e1fd21d4a929))
* add governance strategy ([47dc9f2](https://github.com/rigoblock/v3-contracts/commit/47dc9f20ec5032fd41983d2f2699af0a216d3dab))
* add salt to EIP-712 domain, hash governance strategy ([82efffb](https://github.com/rigoblock/v3-contracts/commit/82efffbcd6ca971c3a5ba4e3487e23305d0606b8))
* allow instant execution if > 2/3 of all active stake in support ([8057d5a](https://github.com/rigoblock/v3-contracts/commit/8057d5ae06fb7e06563b8df0b807a79b84f86ba2))
* assert valid governance init params ([7d2fa59](https://github.com/rigoblock/v3-contracts/commit/7d2fa5984c1870b27ede72fc448bdb32e22024ee))
* move proposal state verification to strategy ([d04f51c](https://github.com/rigoblock/v3-contracts/commit/d04f51c834017f5a60b305644bf49bef2960dc10))
* return proposal list in proposal wrapper tuple ([13a26df](https://github.com/rigoblock/v3-contracts/commit/13a26df2a092382ad37dd7edfcef6cfec3c869e7))
* revert with rich error when execution fails ([1b177af](https://github.com/rigoblock/v3-contracts/commit/1b177af2ad91c7af7eea880bbc1bb87394c1b4c5))
* safer governance implementation initialization ([a06b0a5](https://github.com/rigoblock/v3-contracts/commit/a06b0a5efa4ef84ea2367f745ed0ddab69cd0ce9))
* simplify domain separator computation ([3977e77](https://github.com/rigoblock/v3-contracts/commit/3977e77a291817523c06e3a7c3104e40ebb80d4e))
* split governance in subcontracts and abstract storage ([c8dad0f](https://github.com/rigoblock/v3-contracts/commit/c8dad0fd43f6b7629973e838ee8361347c50cb47))
* split governance interface in subcontracts and reorg code ([aceba44](https://github.com/rigoblock/v3-contracts/commit/aceba444e151ccba5d596cc43495ef7bc3d948f7))
* update EIP-712 domain at implementation upgrade ([2849adb](https://github.com/rigoblock/v3-contracts/commit/2849adbe4b28d25652b88b6a6f22418eb56a21cc))
* upgrade governance strategy ([939fecb](https://github.com/rigoblock/v3-contracts/commit/939fecb67436f359c6b55403cb914a77e346ddf2))
* validate params in governance strategy ([4136a57](https://github.com/rigoblock/v3-contracts/commit/4136a576c9edf4334e65137e2b267e2315a68c87))



## [1.1.2](https://github.com/rigoblock/v3-contracts/compare/v1.1.1...v1.1.2) (2023-01-18)


### Bug Fixes

* add InflationL2.sol contract ([97b12de](https://github.com/rigoblock/v3-contracts/commit/97b12de06b275f9f6863317895c2d1b096dd211d))
* hardcode inflation address in staking on L2s ([bf7a8e6](https://github.com/rigoblock/v3-contracts/commit/bf7a8e6d23b8564f7b34f67dda73f0c45a2ea32b))
* retrieve chainId in staking constructor without using assembly ([0e8ea5a](https://github.com/rigoblock/v3-contracts/commit/0e8ea5afc7fe0d94dbd0d42984fcd49213a2a8b3))
* update husky script ([68f55eb](https://github.com/rigoblock/v3-contracts/commit/68f55eb991eef0fe7dfe0312d4e9199440ced2cf))



