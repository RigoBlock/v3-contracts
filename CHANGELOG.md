## [0.9.1](https://github.com/rigoblock/v3-contracts/compare/v0.9.0...v0.9.1) (2022-09-20)


### Bug Fixes

* add return errors as string in LibMath, LibSafeMath utils ([3c3423b](https://github.com/rigoblock/v3-contracts/commit/3c3423be9d1b2ae66cde3f7aaed49a4177977728))
* complete staking adapter ([90fb96d](https://github.com/rigoblock/v3-contracts/commit/90fb96d7523b9884cf885aba3efe8eba47ef83ec))
* finalize before withdrawing rewards and read from private ([85df039](https://github.com/rigoblock/v3-contracts/commit/85df0396be1f24d0c3e7a1184baf77ca801711e1))
* removed unused library methods ([0d41969](https://github.com/rigoblock/v3-contracts/commit/0d41969735218a8939c274229230a57d5cf96070))
* removed unused private method in staking ([126fe36](https://github.com/rigoblock/v3-contracts/commit/126fe36d22952bb8b95f8311d41c075ef5cdb04e))
* updated staking adapter interface with new methods ([d2991ce](https://github.com/rigoblock/v3-contracts/commit/d2991ce7941d78537736b51521f0639eff14a1f7))



# [0.9.0](https://github.com/rigoblock/v3-contracts/compare/v0.8.0...v0.9.0) (2022-09-17)


### Bug Fixes

* add nav verifier adapter interface ([a482b17](https://github.com/rigoblock/v3-contracts/commit/a482b17c7ae942006b38daa3da08ac0172a03f97))
* add staking adapter interface ([c506819](https://github.com/rigoblock/v3-contracts/commit/c506819839701a0ecd04e6def94596ad1f9db5d9))
* added missing overrides in adapters ([fe92c84](https://github.com/rigoblock/v3-contracts/commit/fe92c847fafec1a66a0695b294ca111706c40b58))
* all adapters inherit method and docs from their interfaces ([79cf7dd](https://github.com/rigoblock/v3-contracts/commit/79cf7dd8b747c9fb0a55738f5808bed9b3106b11))
* check valid nav inside setUnitaryValue method ([9e8bbe3](https://github.com/rigoblock/v3-contracts/commit/9e8bbe3ce8de68e786d3dc7fbbdc945bbfe62433))
* declare uniswap adapter method refund eth as virtual ([29afe26](https://github.com/rigoblock/v3-contracts/commit/29afe26eefdd3a05775f66f24ed17195f6061040))
* deprecate nav verifier extension ([f987cc5](https://github.com/rigoblock/v3-contracts/commit/f987cc5c652c66c7a59c5d8f271ea257e687151c))
* do not require self custody account to be EOA ([b5ce495](https://github.com/rigoblock/v3-contracts/commit/b5ce495d4b52120323ecc08e575e2acba3cca611))
* import weth9 in AUniswap v3 ([14abf83](https://github.com/rigoblock/v3-contracts/commit/14abf83a8729b48f030ddb2ba894e9d43e1435f6))
* make uniswap npm adapter abstract ([873fc1b](https://github.com/rigoblock/v3-contracts/commit/873fc1b2a42acdb7b41667b7addf5c467efc4b41))
* move multicall to dedicated adapter ([f046332](https://github.com/rigoblock/v3-contracts/commit/f046332ba71c3b43b74caf77bc40074c4eb41c16))
* nav verifier adapter inherits from interface ([bb4fef3](https://github.com/rigoblock/v3-contracts/commit/bb4fef3ba1d042b3d3631399c23076339edc9d94))
* remove unused inputs in set unitary value ([ab9a7ea](https://github.com/rigoblock/v3-contracts/commit/ab9a7eaf89befd80c50ad74d322348769127ebd0))
* rename mint/burn in pool to prevent signature clashing ([3eadf68](https://github.com/rigoblock/v3-contracts/commit/3eadf68b2660566efab8903c600ca550caad9fe9))
* safe approve gas optimization and uniswap adapter minor linting ([5c99829](https://github.com/rigoblock/v3-contracts/commit/5c99829d54545024f46b0a61f8301c80ab3e5307))
* staking adapter inherits from interface ([2dda2fd](https://github.com/rigoblock/v3-contracts/commit/2dda2fd4de384e0f317d3f1dc5af905cc5d974a2))
* uniswap npm improvements ([eca81ac](https://github.com/rigoblock/v3-contracts/commit/eca81acedaac50f09ccc9b7ea7c25d1c5aaa0c54))
* unwrap eth directly from weth contract in npm adapter ([c4397c5](https://github.com/rigoblock/v3-contracts/commit/c4397c543d93068fe747bd5b2452cde43b205c02))
* update pool actions interface ([a0226ec](https://github.com/rigoblock/v3-contracts/commit/a0226ecde4b72abcb8a121413e4fa80a4b84e74a))
* update solc to >= from = in self custody adapter interface ([38ac8fe](https://github.com/rigoblock/v3-contracts/commit/38ac8fe7dab6fe09989d76d68327c61d7e95c631))
* update uniswap npm adapter for supporting eth incoming transfers ([3c69579](https://github.com/rigoblock/v3-contracts/commit/3c695798c6ea8525e89ef22fcbf1d3b1a56d0cb9))


### Features

* add minimum received in pool mint/burn ([6dafb40](https://github.com/rigoblock/v3-contracts/commit/6dafb40329069b3d3e89bef269258c7fb991899a))
* add uniswap adapter in deploy/tests pipeline ([0087cd6](https://github.com/rigoblock/v3-contracts/commit/0087cd68f8b0aca04d0967ef49d188f57ac6b98f))
* added mock uniswap npm contract ([d6f0a57](https://github.com/rigoblock/v3-contracts/commit/d6f0a578e2351bea74ca6531e59f51e934342e68))
* require at least 3% liquidity when updating pool price ([d2e8965](https://github.com/rigoblock/v3-contracts/commit/d2e8965944d54af83caedc1e767a469a1d5c2734))
* update uniswap adapter ([0e698fb](https://github.com/rigoblock/v3-contracts/commit/0e698fb302d0bebd801a1a9594cc288bfa1e695b))



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



