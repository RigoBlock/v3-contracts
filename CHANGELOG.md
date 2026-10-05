## [2.8.2](https://github.com/RigoBlock/v3-contracts/compare/v2.8.1...v2.8.2) (2026-10-05)


### Bug Fixes

* **gmx:** require pool price feed for both market tokens at order admission ([e489152](https://github.com/RigoBlock/v3-contracts/commit/e489152c1a63ddcd2f407779e5f52c49ec16349a))



## [2.8.1](https://github.com/RigoBlock/v3-contracts/compare/v2.8.0...v2.8.1) (2026-10-01)


### Bug Fixes

* bump version to prompt redeployment ([5b286c7](https://github.com/RigoBlock/v3-contracts/commit/5b286c77e929513a805fc12b0aef2139e4963cf6))
* prevent cascade imports for artifacts by moving type to own type ([edf8fee](https://github.com/RigoBlock/v3-contracts/commit/edf8fee1490ac1adcf2c6be0b6e9a916a9d1d5a7))



# [2.8.0](https://github.com/RigoBlock/v3-contracts/compare/v2.7.0...v2.8.0) (2026-09-30)


### Bug Fixes

* address gmx breaking change ([2727784](https://github.com/RigoBlock/v3-contracts/commit/272778415368921a4f9043b1588f40e27bf2f243))
* NavView NAV parity aggregation, fork block bumps, solc 0.8.37 ([c14f233](https://github.com/RigoBlock/v3-contracts/commit/c14f23338f7296948addddd9fa3a7a94600066f8))
* RIGO-200 quorum snapshot for legacy proposals ([b3486ff](https://github.com/RigoBlock/v3-contracts/commit/b3486ff3b46d1e3baa2f704301ddb55e71da9970))
* support gmx breaking changes ([aa8ec50](https://github.com/RigoBlock/v3-contracts/commit/aa8ec50726e7da3145cc3ff651f2636658368086))


### Features

* add Tally compatibility missing methods ([f44d3ed](https://github.com/RigoBlock/v3-contracts/commit/f44d3edc4831a135601dae8edb7c0d43777e7a2a))
* align specs with Tally compatibility reqs ([219b1d7](https://github.com/RigoBlock/v3-contracts/commit/219b1d712e57c8c149a65a36788ef77283167e31))
* bump gov solc from 0.8.35 to 0.8.37 ([3f8d630](https://github.com/RigoBlock/v3-contracts/commit/3f8d63001127dadab444e498fbb3052a40b98e87))
* bump solc from 0.8.28 to 0.8.37 everywhere ([f9f0d0a](https://github.com/RigoBlock/v3-contracts/commit/f9f0d0ad4343e350557481547ed73e9b5751a6ed))
* compile AUniswapRouter with solc 0.8.37 via isolated forge job ([8d4237f](https://github.com/RigoBlock/v3-contracts/commit/8d4237f52bcc102edf0335001d7d0553e67d4cb4))
* crosschain governance ([89daa51](https://github.com/RigoBlock/v3-contracts/commit/89daa5164479815954f6dea6f5864180396975fd))
* implement cancel proposal ([e36c74a](https://github.com/RigoBlock/v3-contracts/commit/e36c74aeefad8c4b69dda581af0268314e07d89e))
* nonces storage definitions ([9697c59](https://github.com/RigoBlock/v3-contracts/commit/9697c5971f1a36f6a396d6b2a83c8c9aa298e5a5))



# [2.7.0](https://github.com/RigoBlock/v3-contracts/compare/v2.6.4...v2.7.0) (2026-09-12)


### Bug Fixes

* canonicalize all CBOR blobs so unchanged contracts reproduce CREATE2 addresses ([9a293fc](https://github.com/RigoBlock/v3-contracts/commit/9a293fc3372a8b3c9d179cf15f27dcdff5b7ec69))
* deploy through Safe singleton factory on production chains ([b22cc0f](https://github.com/RigoBlock/v3-contracts/commit/b22cc0f252f84202a8780b03bcd0c2aee8e33b31))
* move disabled ERC20 methods to EERC20 extension, restore deployable SmartPool size ([c080103](https://github.com/RigoBlock/v3-contracts/commit/c080103779d9362abe1edf4092bb669da3d38fa5))
* scope hardhat coverage to foundry parity via coverage.skipFiles ([fe00628](https://github.com/RigoBlock/v3-contracts/commit/fe006283a442099d4886cd6d9d41593ce333693c))


### Features

* canonical CBOR tails restore cross-chain CREATE2 parity under Hardhat 3 ([a2e3638](https://github.com/RigoBlock/v3-contracts/commit/a2e3638ebb1e2ef4184ec5b2c6b21e6d796a821b))
* fail closed when deploying to an unconfigured live chain ([9abdbd0](https://github.com/RigoBlock/v3-contracts/commit/9abdbd0a7502390c2bf4c1c5fbe8b61281afbe40))



## [2.6.4](https://github.com/RigoBlock/v3-contracts/compare/v2.6.3...v2.6.4) (2026-09-12)


### Bug Fixes

* same block nav lock on hyperEvm ([db2816f](https://github.com/RigoBlock/v3-contracts/commit/db2816f0a9a987a352919dac32e0ef02fb66dfe9))



