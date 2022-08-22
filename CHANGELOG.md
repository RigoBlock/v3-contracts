# [0.8.0](https://github.com/rigoblock/v3-contracts/compare/v0.7.0...v0.8.0) (2022-08-22)


### Bug Fixes

* add log indexed base token at pool initialization ([53afe47](https://github.com/rigoblock/v3-contracts/commit/53afe47b7d21f10cd8d92fe761d437d05dc38b5c))
* add pool initializer interface to pool interface ([0cd5c68](https://github.com/rigoblock/v3-contracts/commit/0cd5c68d2a83a910d2c11b3408c278a07d5dc133))
* add receive to interface and do nothing when eth received ([f0e2656](https://github.com/rigoblock/v3-contracts/commit/f0e26565ad5bd5c2203faf18b0e5dd5677cf1849))
* allow spread up to 10% instead of < 10% ([e345a45](https://github.com/rigoblock/v3-contracts/commit/e345a45121ef9763dd481e845212ee49d4063b52))
* fix typo in burn method plus get fee collector from internal method ([1454005](https://github.com/rigoblock/v3-contracts/commit/14540052e17c2dc2b57db6b937e3fa5cc006fd88))
* fixed returned error message when failed transfer from pool ([f378fb7](https://github.com/rigoblock/v3-contracts/commit/f378fb76df8f176a9119f3433a5563e3a0c4d880))
* hash name and owner address to produce salt ([7553ccc](https://github.com/rigoblock/v3-contracts/commit/7553cccbde8b7814a5907d2697d91f0322e7dc7d))
* implement overrides in mixin pool state and virtual elsewhere ([e8dae35](https://github.com/rigoblock/v3-contracts/commit/e8dae35ab4c303df236f5845de607b9c157139e3))
* make public 2 methods in pool (prev external) and remove TODO ([f9171c8](https://github.com/rigoblock/v3-contracts/commit/f9171c8d63145398671c46db6d912d3c2df3b1e6))
* moved unused Atoken and AWeth to examples folder ([2486b46](https://github.com/rigoblock/v3-contracts/commit/2486b46a7e0de50b0bfe52e8b1dc5a010954d3b0))
* renamed factory internal method _createPoolInternal to _createPool ([8332f9f](https://github.com/rigoblock/v3-contracts/commit/8332f9f5aade330e0be5e1030a7f6bf369cf4d56))
* require kyc provider is contract ([6238e6f](https://github.com/rigoblock/v3-contracts/commit/6238e6f7eb771ca8879f30b7ef41ca0f252c4e4d))
* require target not contract in self custody adapter ([c5322f9](https://github.com/rigoblock/v3-contracts/commit/c5322f9c49143f7bdcaebcb0d20c3cadb3706429))
* return fee collector from internal method ([136c62f](https://github.com/rigoblock/v3-contracts/commit/136c62f1819fe6dba4981ecf792abd47f5c0b1d0))
* returned variable naming ([4e1058a](https://github.com/rigoblock/v3-contracts/commit/4e1058ad5bc46750a82ff7116208cb8162e31c9f))
* revert if spread set to 0 ([97ae7f3](https://github.com/rigoblock/v3-contracts/commit/97ae7f3d19e538f788002a6cde64d7949e7c3e59))
* update order of subcontracts import and declare storage import ([8a647b3](https://github.com/rigoblock/v3-contracts/commit/8a647b3430cddbdde9c48b8e647f5f5d1a113617))
* update pool subcontracts interfaces correctly ([6410220](https://github.com/rigoblock/v3-contracts/commit/6410220ddad288851289fe693ab72ef96347e438))


### Features

* added self custody adapter interface ([463b293](https://github.com/rigoblock/v3-contracts/commit/463b29339487320e2cd8969c469ce9dc5096009f))
* complete migration of pool methods to subcontracts ([cb9294d](https://github.com/rigoblock/v3-contracts/commit/cb9294d0ee957c244d04437d0edd32c84fce6fcb))
* move owner actions to dedicated subcontract ([4c12833](https://github.com/rigoblock/v3-contracts/commit/4c12833a6d6af318d155ccafbe728a9277d3bc0a))
* move storage and init constants to subcontracts ([8fdf8bf](https://github.com/rigoblock/v3-contracts/commit/8fdf8bfd7f4f749b9adac6050ff2eb4ceedd798e))
* move user actions to abstract subcontract ([8df8451](https://github.com/rigoblock/v3-contracts/commit/8df845111a07e85721de5b3e7f1de36b776d8c76))
* simplify self custody and require minimum delegated GRG stake ([0746a27](https://github.com/rigoblock/v3-contracts/commit/0746a27dc1f7ea676356e87347d1f4e782995c3d))



# [0.7.0](https://github.com/rigoblock/v3-contracts/compare/v0.6.0...v0.7.0) (2022-07-27)


### Bug Fixes

* assert instead of revert with reason in inflation ([ca1add6](https://github.com/rigoblock/v3-contracts/commit/ca1add6419cecbaf9184a61a9063849c6dd355de))
* correctly delete from storage when removing in authority ([11099ad](https://github.com/rigoblock/v3-contracts/commit/11099ad0bafea6892d37a3753424283b71090dda))
* declare isValidNav as pure instead of view ([b9562db](https://github.com/rigoblock/v3-contracts/commit/b9562dbba7886b5dff148d7de3e2f74d9f5a9144))
* further authority linting ([c78416f](https://github.com/rigoblock/v3-contracts/commit/c78416ff9fefcd7625fa75727be716b053b53e49))
* further simplify authority core ([92fedd8](https://github.com/rigoblock/v3-contracts/commit/92fedd8f670523c1c056faca291343bb5e2a1c06))
* just assert without return error in staking adapter ([8cc2272](https://github.com/rigoblock/v3-contracts/commit/8cc22724f36be68b2d6a50c65ea274bfb643d666))
* minimum amount as base / 1e3 instead of value / 1e3 ([0a89c3b](https://github.com/rigoblock/v3-contracts/commit/0a89c3ba755590e31e74ac5a0c0bfb977c4dc127))
* pool registry linting ([a8cebd9](https://github.com/rigoblock/v3-contracts/commit/a8cebd990979664a6bee525cc630830af6c7bbc7))
* remove authority exchanges use in weth adapter  ([36395f6](https://github.com/rigoblock/v3-contracts/commit/36395f68079403cd61fc1ab77804e027b02ed1d9))
* remove concept of authority group ([1ff95a5](https://github.com/rigoblock/v3-contracts/commit/1ff95a543fd3fd3c7d4cc79eb14d2c07d3a75e0d))
* remove use of authority extensions in pool ([5245c39](https://github.com/rigoblock/v3-contracts/commit/5245c3930d0f6b62f42c3fd2609e4fd68c27f041))
* rename internal to private in inflation and rename internal method ([ffe0261](https://github.com/rigoblock/v3-contracts/commit/ffe026192a289ca9d22b63cafc387ec3f96407fa))
* revert with error in inflation time anomaly instead of assert ([752d186](https://github.com/rigoblock/v3-contracts/commit/752d186cacd266622416504a63bee477b32acc0a))
* upgrade solc  dep to 0.8.15 from 0.7.4 ([653365e](https://github.com/rigoblock/v3-contracts/commit/653365e69d712a3b895a218f8a7377cb9924973b))


### Features

* better naming convensions in authority and registry modifier ([71e52af](https://github.com/rigoblock/v3-contracts/commit/71e52af937840eeda61d0e475d41e67c605d5874))
* simplify authority contract ([e53c111](https://github.com/rigoblock/v3-contracts/commit/e53c111f2b9fe43ae53b991b6e6a49b23f181b74))
* simplify authority core storage ([37e0226](https://github.com/rigoblock/v3-contracts/commit/37e022642dcdfedeb696eb550c2dd4cf72f1591f))
* simplify authority extensions storage ([bc07a2c](https://github.com/rigoblock/v3-contracts/commit/bc07a2c58953089f6137a6a7de5879654b72eab5))



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



