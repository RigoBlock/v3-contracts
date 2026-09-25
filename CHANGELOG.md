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



## [2.6.3](https://github.com/RigoBlock/v3-contracts/compare/v2.6.2...v2.6.3) (2026-09-10)


### Bug Fixes

* 1wei donate rounding error ([5d79afd](https://github.com/RigoBlock/v3-contracts/commit/5d79afd46f748db2e3e1a7f9e9dd4727da5cebe0))



## [2.6.2](https://github.com/RigoBlock/v3-contracts/compare/v2.6.1...v2.6.2) (2026-09-07)


### Bug Fixes

* document gmx fallback heartbeat, zero-price nav semantics and oracle twap window arithmetic ([029fccf](https://github.com/RigoBlock/v3-contracts/commit/029fccf8cd2d83757b7d96c02525a0e0d0a17e52))



## [2.6.1](https://github.com/RigoBlock/v3-contracts/compare/v2.6.0...v2.6.1) (2026-09-04)


### Bug Fixes

* EOracle conversion ([612be46](https://github.com/RigoBlock/v3-contracts/commit/612be468ea1cfd964ebf41036e47c8e3fc9b2295))
* gmx mappings ([1cd38e3](https://github.com/RigoBlock/v3-contracts/commit/1cd38e36fdbd1c63013efa16bf8699e40d547a89))



