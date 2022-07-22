# [0.6.0](https://github.com/rigoblock/v3-contracts/compare/v0.5.0...v0.6.0) (2022-07-22)


### Bug Fixes

* add ERC20 proxy contract and deps ([be00be7](https://github.com/rigoblock/v3-contracts/commit/be00be709b2dd93193801ac2e9105e2d83c79205))
* add event to factory ([c1ed72d](https://github.com/rigoblock/v3-contracts/commit/c1ed72dae136bf29dbf0bb56c0b212232d71ddab))
* add revert reason to stake method ([e7bbe1f](https://github.com/rigoblock/v3-contracts/commit/e7bbe1f4420e898b7921e3345d4f3ebebeb26b3f))
* initialize owner in constructor for staking, proxy, vault ([f17aa09](https://github.com/rigoblock/v3-contracts/commit/f17aa09f2cf7af0e13cf23b9b975e7ebd1adf78f))
* initialize staking deployment immutables in constructor ([303807f](https://github.com/rigoblock/v3-contracts/commit/303807f487b8b0b57707b17d12274fc8d9be768e))
* move modifier from pop mgr o pop rewards contract ([1991a77](https://github.com/rigoblock/v3-contracts/commit/1991a773df607c2e7cef8fd970c3e09857bd039d))
* remove LibStakingRichErrors and imports ([1953cac](https://github.com/rigoblock/v3-contracts/commit/1953cac3bd4cf597e351ab9fb28306f4d2112cd6))
* simplify mixin staking pool rich return errors ([1fb2482](https://github.com/rigoblock/v3-contracts/commit/1fb2482c0c2f1e6109e378862850c42980ed4f1a))
* simplify pop manager rich returned errors ([5fec6c5](https://github.com/rigoblock/v3-contracts/commit/5fec6c5070d12fea5659f4eb11433e015e5d1715))
* update staking deployment pipeline to staking updates ([e429dcf](https://github.com/rigoblock/v3-contracts/commit/e429dcfede0920d5e524f34762b81b8404d14403))


### Features

* add staking adapter to tests deploy pipeline ([6b62784](https://github.com/rigoblock/v3-contracts/commit/6b62784e115f4cbf6a399ccb7e2e2b79b77246e2))
* create staking adapter ([021c24a](https://github.com/rigoblock/v3-contracts/commit/021c24aabfabfa2b016cc83982b410db9a8aa561))
* create staking pool from rigoblock pool if doesn't exist ([c38845a](https://github.com/rigoblock/v3-contracts/commit/c38845a68d0ecb363266ea2b70e7a3d3688bf8cb))
* remove use of encoded rich error for return rich errors in staking ([5a6b85d](https://github.com/rigoblock/v3-contracts/commit/5a6b85db370fdb2afa93e4c008006d9a9bd1ea82))
* whitelist adapter in extensions authority ([34974db](https://github.com/rigoblock/v3-contracts/commit/34974db6038ecd406caccef35cf2f9f63784b3ce))



# [0.5.0](https://github.com/rigoblock/v3-contracts/compare/v0.4.0...v0.5.0) (2022-07-18)


### Bug Fixes

* correctly initialize rigo token with deterministic deployment ([5ee6b46](https://github.com/rigoblock/v3-contracts/commit/5ee6b463374094ad05c485d4db20c1ab7e12373e))
* do not save name and symbol string in memory at pool creation ([fb298dc](https://github.com/rigoblock/v3-contracts/commit/fb298dc104097cd38a518467c8b5fbb7078eddc5))
* improve pool checks and reorg methods ([7eac151](https://github.com/rigoblock/v3-contracts/commit/7eac151cfc3be8e08d5c80ec1bcfc56d653968ef))
* make 1 pool method private (prev. external) ([a39c95c](https://github.com/rigoblock/v3-contracts/commit/a39c95c1964954e5c8aa77bb6beecf44584759d5))
* merge positive amount modifier into burn method ([5412535](https://github.com/rigoblock/v3-contracts/commit/5412535b97dc462c1cafe8fca3980410909abbc3))
* move sigverifier to examples and made abstract, simplified contract ([5d1bcaf](https://github.com/rigoblock/v3-contracts/commit/5d1bcaf9573a32665780ecd84e43bf0760a9e81c))
* override pool decimals and set base token ([9f85f2d](https://github.com/rigoblock/v3-contracts/commit/9f85f2d7395a97ed74a9b27f0580502385beb952))
* prevent flashbot attacks by setting pool initial lockup = 1 ([9a7b52b](https://github.com/rigoblock/v3-contracts/commit/9a7b52bebee864c086b9162447f80216aa186477))
* remove  pool siverifier method as call delegated to adapter ([d765a6d](https://github.com/rigoblock/v3-contracts/commit/d765a6d480c50fb6a802ba4d0c21508c27e1bda8))
* remove deprecated eventful contract related methods in authority ([f69d726](https://github.com/rigoblock/v3-contracts/commit/f69d7262088e07243ec93d55e8d5e674176d0d7b))
* remove mint/burn events and user transfer with address 0 ([3046fa1](https://github.com/rigoblock/v3-contracts/commit/3046fa1aba0e70a719e9c1c6e414a951a71781bb))
* rename pool method ([d7dd789](https://github.com/rigoblock/v3-contracts/commit/d7dd789d1043545ee49cfbc3fd5cb4637584e99e))
* simplify logic of pool mint/burn methods and variables renaming ([8f80a60](https://github.com/rigoblock/v3-contracts/commit/8f80a605a4d4fef2a9c39021252e5d082942a6e9))
* update authority extensions selector related methods ([93244c3](https://github.com/rigoblock/v3-contracts/commit/93244c3ae86956d0be81f86eaf5ec9e0d197ca0b))
* update nav verifier to single price specs ([2b08d32](https://github.com/rigoblock/v3-contracts/commit/2b08d32058852069e8fc27c6d6ee18634623f895))
* update new nav log msg ([7d99181](https://github.com/rigoblock/v3-contracts/commit/7d991814bd748ec243acb83d1b92d76f9398bc74))
* update pool interfaces ([a954011](https://github.com/rigoblock/v3-contracts/commit/a954011ab0353faaa722affd08813b6a52b8210d))
* updated README.md ([02fbe47](https://github.com/rigoblock/v3-contracts/commit/02fbe47cd9757b8c3b7b0f4cb156382f9932c04b))


### Features

* add base token return value in get pool data ([4b6dd72](https://github.com/rigoblock/v3-contracts/commit/4b6dd72889f5556e0b86f33d7eed6fe06674bee8))
* do not require unique name to prevent race conditions ([2213f27](https://github.com/rigoblock/v3-contracts/commit/2213f27fb792cf01aaa5b31c705e79dc38506c04))
* implement generic fallback in pool implementation ([57f2d99](https://github.com/rigoblock/v3-contracts/commit/57f2d99bcdc11aeec94e41ae1ed3dc9ef60ed86e))
* merge buy and sell prices in pool, introduce spread ([0ee6f0a](https://github.com/rigoblock/v3-contracts/commit/0ee6f0a1f8cc853f04f4574c08e497c1ea9fe828))
* minimum order check with small-decimals tokens ([27212ea](https://github.com/rigoblock/v3-contracts/commit/27212ea5dd8d1e0104f57ddd614728874d72c0ef))
* remove dao fee and remove related variables, methods, deps ([57ff575](https://github.com/rigoblock/v3-contracts/commit/57ff5759bf2140678c8bfdc46f5a5fb7110baa02))



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

* ci bump package version ([a8620d6](https://github.com/rigoblock/v3-contracts/commit/a8620d647d786074298ec33b2f6aae8cd87f7998))
* use conventional changelog instead of github tag action ([ad8e887](https://github.com/rigoblock/v3-contracts/commit/ad8e88753ff2da04d24619d5b3e499602fccd4b6))



