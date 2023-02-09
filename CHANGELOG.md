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



## [1.1.1](https://github.com/rigoblock/v3-contracts/compare/v1.1.0...v1.1.1) (2022-10-26)


### Bug Fixes

* add uniswap extended uniswap methods ([64ef4a3](https://github.com/rigoblock/v3-contracts/commit/64ef4a3c3a22c537e975017732332af53f32740f))
* deprecate LibSafeMath in staking ([d5fc4a9](https://github.com/rigoblock/v3-contracts/commit/d5fc4a9ba679bf990b96d79b3e94348416113bcc))
* initialize staking pal to null address if is operator ([caeec6d](https://github.com/rigoblock/v3-contracts/commit/caeec6dffd977a346406bc6ac9305680eb888956))
* internal constants renaming with _ ([b953767](https://github.com/rigoblock/v3-contracts/commit/b95376752c8f93bd5688a3e50cd51dc01514ef1e))
* IStorage missing methods, removed non implemented plus docs ([f39cfc3](https://github.com/rigoblock/v3-contracts/commit/f39cfc3204b21639f9337220329e84b1e6948542))
* minor staking variables renaming ([3ed91f5](https://github.com/rigoblock/v3-contracts/commit/3ed91f51e76f5e428220d04d8a58a94758b76f3e))
* mixin deployment constants ([4d5014d](https://github.com/rigoblock/v3-contracts/commit/4d5014d3aed9691754059ab517ad50ddac12cc1c))
* remove use of LibSafeMath in staking ([8216d2f](https://github.com/rigoblock/v3-contracts/commit/8216d2f66b17fd03580e424c4c51db5bad2e582a))
* simplify math operationsin stake storage ([fa62f7b](https://github.com/rigoblock/v3-contracts/commit/fa62f7ba79fa963eb76ea0cc3216a6fc18831dcf))
* update multicall interface with extended methods ([46eac10](https://github.com/rigoblock/v3-contracts/commit/46eac10706ce5462d0bb84551f414a40f17c7928))
* upgrade minimum rigo token interfaces solc ([7ac33a1](https://github.com/rigoblock/v3-contracts/commit/7ac33a1394e8f3a5489743156df6318d237b8583))



# [1.1.0](https://github.com/rigoblock/v3-contracts/compare/v0.11.1...v1.1.0) (2022-10-19)


### Features

* upgrade version to v3.0.1 ([999e9bf](https://github.com/rigoblock/v3-contracts/commit/999e9bf98d997f3cceb82db24b9cac0ca87b5268))



