# [0.4.0](https://github.com/rigoblock/v3-contracts/compare/v0.3.0...v0.4.0) (2022-07-12)


### Bug Fixes

* allow set meta for registered pools only ([cadc5bf](https://github.com/rigoblock/v3-contracts/commit/cadc5bf53db8d2ce01b927f0c51caf92c8b253f6))
* correctly initialize pool implementation deploy variables ([dc586ad](https://github.com/rigoblock/v3-contracts/commit/dc586ad6db097cbfdbaa4969903df85719fb2392))
* define pool implementation immutable storage in state interface ([f63d0e6](https://github.com/rigoblock/v3-contracts/commit/f63d0e627f4e1dd2e3c8ac3de988a0575702c04a))
* move dao set/set methods from factory to registry ([f24edc7](https://github.com/rigoblock/v3-contracts/commit/f24edc75c5e81bc362a28323d4ab6acef83b5ab5))
* pool implementation add overrides in public variables ([f2a6a43](https://github.com/rigoblock/v3-contracts/commit/f2a6a43239de6f0757068cd73125c4dcf24f6927))
* pool registry is not owned and updated deploy input ([adc0f3c](https://github.com/rigoblock/v3-contracts/commit/adc0f3c750cde514af940d6e2281610cbf85cfd9))
* proxy import deps plus constructor gas optimizations and linting ([7274cf5](https://github.com/rigoblock/v3-contracts/commit/7274cf5b58dde7c337be6720a39126e99f9f6b14))
* remove fee methods in factory as pay() not implemented ([7e2ef76](https://github.com/rigoblock/v3-contracts/commit/7e2ef762cbb1d81ff278c6df8dfb887bb4799423))
* rename factory storage variables and remove struct ([ac7aec1](https://github.com/rigoblock/v3-contracts/commit/ac7aec1937db52f30771f14ac1f35b6bdf447910))
* rename variable drago to pool and methods to mint and burn ([d33a5ba](https://github.com/rigoblock/v3-contracts/commit/d33a5ba42fa219cc805a6f5e347d8870f2a0644b))
* updatable authority in registry and improved new input checks ([ad86357](https://github.com/rigoblock/v3-contracts/commit/ad86357a70707ef45cb426a8f6ba84c8f5bbb23f))


### Features

* add pool tests ([089fa06](https://github.com/rigoblock/v3-contracts/commit/089fa06d71726e7fc3ca7b96a65b6f7c514c6018))
* emit log when beacon upgrades implementation ([ec44f44](https://github.com/rigoblock/v3-contracts/commit/ec44f4425e3fdaa2ed6e80a0603c95bceb38000f))
* emit pool initialization log ([0891009](https://github.com/rigoblock/v3-contracts/commit/08910091ab43bdc8581c3407971076ec2fa48cfe))
* factory now Owned and does not set target pool dao address ([ae9308a](https://github.com/rigoblock/v3-contracts/commit/ae9308a0844e81c0a14b74fe87d6d454e49d751b))
* move allowance setting from pool to adapter and improve init check ([b1afcc0](https://github.com/rigoblock/v3-contracts/commit/b1afcc0693d28497940d621784447a001c156986))
* move storage slot library to own file ([e4fd6a6](https://github.com/rigoblock/v3-contracts/commit/e4fd6a60cb3e6e39cd2f928577be51463049d125))
* remove allowance after op without clearing storage ([84a9a52](https://github.com/rigoblock/v3-contracts/commit/84a9a52c594dc72fbab171621d8c3be2dc81a92f))
* remove dao intervention in pool ([1d2ec9c](https://github.com/rigoblock/v3-contracts/commit/1d2ec9c6b9f0b8cf1c51ab4c3e9e59fe9dd09149))
* remove unused authority references from proxy factory ([58b27df](https://github.com/rigoblock/v3-contracts/commit/58b27dfcf6ac461af2ea9364155ebc145cafeb1d))



# [0.3.0](https://github.com/rigoblock/v3-contracts/compare/v0.2.2...v0.3.0) (2022-07-09)


### Bug Fixes

* add overrides in registry ([7f4c322](https://github.com/rigoblock/v3-contracts/commit/7f4c32236ff7486b1892e0297a9ba794beb84f78))
* add return errors in registry ([fa0b21b](https://github.com/rigoblock/v3-contracts/commit/fa0b21b5985fb096b8d47061b171b8b32c6f7b37))
* added missing return method poolIdByRbPoolAccount in IStorage ([b1d0ebd](https://github.com/rigoblock/v3-contracts/commit/b1d0ebdce4bd2bcc14bb49251636429d225e6147))
* factory library creation address check ([a6f9b6e](https://github.com/rigoblock/v3-contracts/commit/a6f9b6e51a8a0406158a73690e64a9a0d3aca635))
* factory pool creation partial rewrite and optimizations ([905a99a](https://github.com/rigoblock/v3-contracts/commit/905a99a20ba31f11e1df53e2a64a712c1833e088))
* factory tests ([6268a9c](https://github.com/rigoblock/v3-contracts/commit/6268a9ce58881909f8c64551cd07007511bc24ba))
* optimize pool creation by not passing duplicate owner address ([b62b0e0](https://github.com/rigoblock/v3-contracts/commit/b62b0e099bb1ffe91776634bbc1647d036be162c))
* pool factory interface linting and renaming drago to pool ([ca7d2bd](https://github.com/rigoblock/v3-contracts/commit/ca7d2bdccc04922d03056f0394e6ce7558af3032))
* pool registry linting and sanitize assertions ([2332054](https://github.com/rigoblock/v3-contracts/commit/2332054a6e42160d79fe73fdccc37fc72333a10f))
* pool registry optimizations plus drago to pool renaming ([32e4748](https://github.com/rigoblock/v3-contracts/commit/32e4748dde3c24d379844ced344b43eed98659da))
* reduce use of assembly in proxy fallback and add commented methods ([96f8c87](https://github.com/rigoblock/v3-contracts/commit/96f8c87c97dfa6086a449dd1f296bbbcb3eea07e))
* sanitize registry name and symbol outside of modifiers  ([92a3152](https://github.com/rigoblock/v3-contracts/commit/92a3152c5052485668f84a9e427d2849b5344528))
* save new pool address in storage in factory library ([3a87397](https://github.com/rigoblock/v3-contracts/commit/3a87397081416e35d43f3d49c4e3f79aa6bece3f))


### Features

* add initial factory tests ([65e0301](https://github.com/rigoblock/v3-contracts/commit/65e030148368bcd86b3f033b4e285f672fa812b1))
* added test contract to estimate pool proxy deploy gas consumption ([897faf5](https://github.com/rigoblock/v3-contracts/commit/897faf5a7097f2bdb7d48a7648ce072b6a373641))
* pool registry refactoring ([6998d01](https://github.com/rigoblock/v3-contracts/commit/6998d012d531447d288f963e4480ad0dbe25a17c))
* query registry from address instead of id and map from address ([544ca6b](https://github.com/rigoblock/v3-contracts/commit/544ca6bc8c2e10eaacae50ff71964f95ab695663))
* refactory pop on pool locked stake instead of own assets ([c2df80b](https://github.com/rigoblock/v3-contracts/commit/c2df80b90277b48024869331562fb3356ccd427e))



## [0.2.2](https://github.com/rigoblock/v3-contracts/compare/v0.2.1...v0.2.2) (2022-06-22)


### Bug Fixes

* add SPDX identifier ([002a14e](https://github.com/rigoblock/v3-contracts/commit/002a14e2348ce375873bd0bf773d96cfdbebadb9))
* add tests setup ([7c26aca](https://github.com/rigoblock/v3-contracts/commit/7c26acaf66efda05666a8e7bbd2aee32e7877d4a))
* ci bump package version ([a8620d6](https://github.com/rigoblock/v3-contracts/commit/a8620d647d786074298ec33b2f6aae8cd87f7998))
* deterministic factory deployment ([03c8feb](https://github.com/rigoblock/v3-contracts/commit/03c8feb9d39b7b88ca776c72ff48266c9a8b9dff))
* deterministic factory deployment ([e722787](https://github.com/rigoblock/v3-contracts/commit/e722787e87f7b7d0e7b9ecae3c8d8d728fffed05))
* event indexing in registry interface ([996d81e](https://github.com/rigoblock/v3-contracts/commit/996d81e6d666a27ec2f99dea5a9adf4d8bdd4703))
* registry contract ([522a51d](https://github.com/rigoblock/v3-contracts/commit/522a51df2c9190b568706a00270381d29e6ffae8))
* removed poolId from factory library ([f311d83](https://github.com/rigoblock/v3-contracts/commit/f311d83ddae3feec5fd2f88aa02ed34fce4a2717))
* revert to correct pool creation flow ([2c72b91](https://github.com/rigoblock/v3-contracts/commit/2c72b9125ba0c6804f861971c41566abbc491a6f))
* set overrides ([26573b1](https://github.com/rigoblock/v3-contracts/commit/26573b1eadedffca1ab759c99f70d490108cb1ac))
* update pragma identifier ([2ce49b0](https://github.com/rigoblock/v3-contracts/commit/2ce49b0716af6fa5956fc681ce02150543c67b71))
* update version script ([75ac5ed](https://github.com/rigoblock/v3-contracts/commit/75ac5ed2f52f3b49db772c2ef7308c64303066c0))
* use conventional changelog instead of github tag action ([ad8e887](https://github.com/rigoblock/v3-contracts/commit/ad8e88753ff2da04d24619d5b3e499602fccd4b6))


### Features

* add contracts tests ([eb7fe1e](https://github.com/rigoblock/v3-contracts/commit/eb7fe1e412bcc4542fe60fb9ecfa74a0fe2e5441))
* publish ([1bfe2b5](https://github.com/rigoblock/v3-contracts/commit/1bfe2b50a5fd61b103ffcbf6e072eb5c15ce2e71))
* remove eventful ([db75691](https://github.com/rigoblock/v3-contracts/commit/db7569194d3c9e67ebee25d45c2cc0f8871bda16))
* rigoblock pool as erc20 interface ([f710282](https://github.com/rigoblock/v3-contracts/commit/f710282d6935bfa74e46d90096b17a217078e5c7))



