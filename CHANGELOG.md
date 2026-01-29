# [2.1.0](https://github.com/rigoblock/v3-contracts/compare/v2.0.7...v2.1.0) (2026-01-29)


### Bug Fixes

* add token jar address ([0d8a29f](https://github.com/rigoblock/v3-contracts/commit/0d8a29fbaab7e2006f68ba2d64ece890fe4073a9))
* Add workspace verification and internal-github-workspace parameter ([f66d366](https://github.com/rigoblock/v3-contracts/commit/f66d36699d4955c4bd3989104511c196b6f0f4b5))
* automatically handle Sync source nav impact ([f0bbc0f](https://github.com/rigoblock/v3-contracts/commit/f0bbc0fe422f5f20aa6e5954e56fff3c0bf5958c))
* base token vb query ([91e5798](https://github.com/rigoblock/v3-contracts/commit/91e5798ff6b9d96d24c0a901ae0f162d92b1a115))
* Compile with Foundry before running Slither ([0d00d44](https://github.com/rigoblock/v3-contracts/commit/0d00d442942345cb8ecf77cc19e1cbacc952fee6))
* correct crosschain addresses and prevent escrow redeployment ([8c3f01f](https://github.com/rigoblock/v3-contracts/commit/8c3f01fe8beceedfe43dadabf27af72a75c01833))
* correctly attribute performance ([e012c9c](https://github.com/rigoblock/v3-contracts/commit/e012c9c9168a254bdd050a370055bac9f63cb818))
* correctly handle null supply edge cases ([58f7e8b](https://github.com/rigoblock/v3-contracts/commit/58f7e8be6b25ec4694f65008a4206732d859f9fc))
* coverage script ([d3faf70](https://github.com/rigoblock/v3-contracts/commit/d3faf70ff6f46c29effadee2acb8004cc1c09cbf))
* default spread to 10bps ([79c2d37](https://github.com/rigoblock/v3-contracts/commit/79c2d3793b761c9b9b4eb4159c545b7b708a8a23))
* emit log when updating active tokens set ([c80c2cb](https://github.com/rigoblock/v3-contracts/commit/c80c2cb03621fd9b58c97879d65f9306f323bd74))
* Escrow future-proofing and across deposit fixes ([006d31a](https://github.com/rigoblock/v3-contracts/commit/006d31afaae5659fce46ab3a2c254f38a3368ccb))
* IOracle tuple params ([7286aaf](https://github.com/rigoblock/v3-contracts/commit/7286aaf24e644c9d85afb98cb976b44cfd107077))
* minor optimization ([fbd6672](https://github.com/rigoblock/v3-contracts/commit/fbd667284cd45254d957f8758ee37c2bd61aeb1a))
* minor supply validation refactoring ([cbb177f](https://github.com/rigoblock/v3-contracts/commit/cbb177f0c38409210a67f7cfa145d4dcceb2c1bd))
* performance rebalancing ([81e7730](https://github.com/rigoblock/v3-contracts/commit/81e7730c47c9a7e5bcf21443a7bf659563236696))
* pre-existing balance reset on uninitialized pool ([f5abcb3](https://github.com/rigoblock/v3-contracts/commit/f5abcb3b2821f6f6e8a8cc96679eb52d604eb414))
* refactor `pdatePoolValue` to return a tuple ([26bc6dc](https://github.com/rigoblock/v3-contracts/commit/26bc6dccc174c8b41b154e0d5c6d2347df415343))
* refactor VB+VS model to use only VS ([14c7cab](https://github.com/rigoblock/v3-contracts/commit/14c7cab01c6ee123b5b1df49ba71557d491b2d97))
* rename deflation to tokenjar ([3e66069](https://github.com/rigoblock/v3-contracts/commit/3e6606942ffa6192bfe3fabdd3f52866b885d44f))
* Replace slither-action Docker with direct Slither installation ([d9b764b](https://github.com/rigoblock/v3-contracts/commit/d9b764bafe757d79f36832fe1e60b2764580d669))
* Security workflow - add ref for PR code, exclude staking contracts, improve error handling ([bc83ef0](https://github.com/rigoblock/v3-contracts/commit/bc83ef0da515821b06a0a6b05090ead8418bd304))
* **security:** compile contracts before slither analysis ([c105e19](https://github.com/rigoblock/v3-contracts/commit/c105e194169396cceb4bf23f74032901ae0cd418))
* **security:** correct slither-args syntax for severity filtering ([5f56a0a](https://github.com/rigoblock/v3-contracts/commit/5f56a0a05a090f66659317acea65b72c1a80fa83))
* smart pool license ([fda9e9e](https://github.com/rigoblock/v3-contracts/commit/fda9e9ebb1a0e3a1dd5e355d76303fbe7533e4c8))
* update nav reentrancy ([682f063](https://github.com/rigoblock/v3-contracts/commit/682f06389e074ea21fc9ef53e2bdb70ac6b02bd6))
* update storage definitions ([e4a20ed](https://github.com/rigoblock/v3-contracts/commit/e4a20ed36d6af1fcdf6f0f8845e5a65b04f71721))
* validate nav integrity also for Sync mode ([d30bba4](https://github.com/rigoblock/v3-contracts/commit/d30bba45f26c700ea0c8cafaa5c38bc865b3c41a))


### Features

* add initial deflation implementation ([a230feb](https://github.com/rigoblock/v3-contracts/commit/a230feb3e9b3bef476396e3c41acba08c29f92b2))
* complete implementation ([988f75e](https://github.com/rigoblock/v3-contracts/commit/988f75e63ce947c58bb0884c61116caae176fab2))
* crosschain transfers ([2fb9823](https://github.com/rigoblock/v3-contracts/commit/2fb98236602fc602a7fe94185de4c12e1b5e67de))
* mint with any token ([5cafa1e](https://github.com/rigoblock/v3-contracts/commit/5cafa1eeb527cd6f455851fdf5eb2be91b551589))
* restrict accepted mint tokens to owner-approved ([97e4bf0](https://github.com/rigoblock/v3-contracts/commit/97e4bf0682753e5ed6057a8bc6fb3489ae3cf771))
* **security:** add local security analysis script ([dd59fb1](https://github.com/rigoblock/v3-contracts/commit/dd59fb1cd2b33d772e9022d0faffaf416ca56861))
* **security:** add manual workflow dispatch and report storage info ([62dee6c](https://github.com/rigoblock/v3-contracts/commit/62dee6c196e6f0fafd30b56fc59d4b2b3c28a257))
* **security:** add Slither static analysis CI workflow ([f4e8e51](https://github.com/rigoblock/v3-contracts/commit/f4e8e515ab816fb78d490d9b6ea0a9858623b162))
* virtual supply ([983dcad](https://github.com/rigoblock/v3-contracts/commit/983dcadf46b6c88983476e41a1a37e2b042a9016))



## [2.0.7](https://github.com/rigoblock/v3-contracts/compare/v2.0.6...v2.0.7) (2025-07-18)


### Bug Fixes

* burn doc ([7073e23](https://github.com/rigoblock/v3-contracts/commit/7073e23a53850c12e03f8ddaeaf8b003f8e9331f))
* prevent owner setting new values same as default ([ef81d89](https://github.com/rigoblock/v3-contracts/commit/ef81d891e94c39ea41f9b617ece9f830934ea6ca))



## [2.0.6](https://github.com/rigoblock/v3-contracts/compare/v2.0.5...v2.0.6) (2025-05-29)


### Bug Fixes

* base token price feed assertion also on first mint ([bf5344b](https://github.com/rigoblock/v3-contracts/commit/bf5344b73da92865b31e076f856acc347c4623ce))



## [2.0.5](https://github.com/rigoblock/v3-contracts/compare/v2.0.4...v2.0.5) (2025-05-25)


### Bug Fixes

* hardhat compile setup in npm publish task ([c79412c](https://github.com/rigoblock/v3-contracts/commit/c79412cbfcee69a5437184d2cec29f5eb5b5e82b))



## [2.0.4](https://github.com/rigoblock/v3-contracts/compare/v2.0.3...v2.0.4) (2025-05-25)


### Bug Fixes

* release script ([d552594](https://github.com/rigoblock/v3-contracts/commit/d5525946c949cfa463417a312c121ca1624ecd0f))



