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



## [0.11.1](https://github.com/rigoblock/v3-contracts/compare/v0.11.0...v0.11.1) (2022-10-19)


### Bug Fixes

* upgrade action-semantic-pull-request to v5.0.2 ([14170ed](https://github.com/rigoblock/v3-contracts/commit/14170ed23462e48f3b65e947f825223174e0c993))
* upgrade actions/checkout in release action ([cdcd1bc](https://github.com/rigoblock/v3-contracts/commit/cdcd1bcd18f1932225c47033b2d6fd5045c9ceb5))
* upgrade ci v3-contracts ([d80e9eb](https://github.com/rigoblock/v3-contracts/commit/d80e9ebcd11d30e65411c6589cb630b405f1dfa9))



# [0.11.0](https://github.com/rigoblock/v3-contracts/compare/v0.10.0...v0.11.0) (2022-10-19)


### Bug Fixes

* assert whitelisted token is contract in whitelist extension ([edbab72](https://github.com/rigoblock/v3-contracts/commit/edbab7258f930a08410432e848c40b34c78d4b08))
* assign token whitelist mapping to struct at defined location ([9abeadd](https://github.com/rigoblock/v3-contracts/commit/9abeadda6670573aef9a0915b3ae012fb940a63a))
* auniswap improvements ([cfb3fe9](https://github.com/rigoblock/v3-contracts/commit/cfb3fe9d5b4fa2552de759654bd455b8963a3790))
* batch deploy used slots in self custody adapter ([8fc4a66](https://github.com/rigoblock/v3-contracts/commit/8fc4a661283dc955713988e87051785036a54334))
* check is contract without using assembly in owner actions ([055aeae](https://github.com/rigoblock/v3-contracts/commit/055aeaecf522c9f249861f1ceb207de323411e44))
* deprecated modifier in mixin pool actions ([86c9a3d](https://github.com/rigoblock/v3-contracts/commit/86c9a3da0ddd4664096d15c020eca6953ab17336))
* minor style fixes ([643020f](https://github.com/rigoblock/v3-contracts/commit/643020fb14042f49a188854f30abeab4689d35a5))
* minor whitelist extension improvements ([f082c43](https://github.com/rigoblock/v3-contracts/commit/f082c43749a78cddaab83dbf397541668bf7605a))
* mixin actions improvements ([5494378](https://github.com/rigoblock/v3-contracts/commit/549437870f6f243a3c85751fb679bf1f7200b2b3))
* owned event log old owner and new owner ([c96e794](https://github.com/rigoblock/v3-contracts/commit/c96e79499b8cbd4f6f7dd9c907a26ad4d3fe29b9))
* owner returned errors renaming, fix log return old, new ([e90fe32](https://github.com/rigoblock/v3-contracts/commit/e90fe320f6d08f592eafdc4660fb0d78bfd756c2))
* proxy deploy gas optimization by directly reading from slot ([21e3ed6](https://github.com/rigoblock/v3-contracts/commit/21e3ed66227ebbcba9511e5cf770170d4098285b))
* reduced uniswap adapter methods execution cost ([506e72b](https://github.com/rigoblock/v3-contracts/commit/506e72b344c92463e5d3dee0098c86584d8c5c90))
* remove sol-hint warnings after check ([84e05b4](https://github.com/rigoblock/v3-contracts/commit/84e05b4114e30a3fb1b20db0219007adf7e986ab))
* require tokens whitelisted for uniswap mint/increase liquidity ([e9ee604](https://github.com/rigoblock/v3-contracts/commit/e9ee604370126e1b66c4461cf14a98028b69751b))
* same address for said owner and name ([ae6fa8a](https://github.com/rigoblock/v3-contracts/commit/ae6fa8a20b19d63aac9fe312f2b498fc4f1cb34e))
* same pool address with upgraded implementation ([62338d4](https://github.com/rigoblock/v3-contracts/commit/62338d45906d9feb2905cb35c1ca471c75e35a59))
* several variables renaming ([95f0323](https://github.com/rigoblock/v3-contracts/commit/95f0323f42833cc492aafe52ea989b16284b8f03))
* simplify mixin initializer by defining decimals before writing Pool ([64aa4fd](https://github.com/rigoblock/v3-contracts/commit/64aa4fd0b561fe0c22a6fcf3566480002b681f3f))
* updated pool interfaces ([32520f3](https://github.com/rigoblock/v3-contracts/commit/32520f3de37747e3a11fac68510f6e4943207e1c))


### Features

* add eip1967 event Upgraded at pool creation ([65d3629](https://github.com/rigoblock/v3-contracts/commit/65d36297ea9bca509fc62949367164987616811b))
* add view methods to return structs ([b4b4c57](https://github.com/rigoblock/v3-contracts/commit/b4b4c574fb12c950957e34a2893a5a8c9d21a2dd))
* deprecate IPoolStructs ([da82e9e](https://github.com/rigoblock/v3-contracts/commit/da82e9eb0e7f04008cc973eae0ac8b0842d44571))
* upgrades at discretion of pool operatos ([e5c8fbb](https://github.com/rigoblock/v3-contracts/commit/e5c8fbb26ab131603e2feb850b3be624e5c11608))


### Reverts

* Revert "minor pool struct gas optimization" ([bfd997f](https://github.com/rigoblock/v3-contracts/commit/bfd997fb71c89129a9917d4cb40369854f16de91))



