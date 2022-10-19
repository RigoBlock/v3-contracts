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



# [0.10.0](https://github.com/rigoblock/v3-contracts/compare/v0.9.1...v0.10.0) (2022-10-08)


### Bug Fixes

* added (commented) missing imported storage slot(1) ([82aabf2](https://github.com/rigoblock/v3-contracts/commit/82aabf27943e529a5608ca3672b3683ae020292b))
* added missing events in pool owner actions and interface ([2bfb79f](https://github.com/rigoblock/v3-contracts/commit/2bfb79f3d84d7af104cd9508ac5be764e26aa62d))
* assert pool decimals > 6 to prevent underflow ([b92ad0b](https://github.com/rigoblock/v3-contracts/commit/b92ad0bfc1aa1a33fcfabb0798c5255f9ec61330))
* do not assert in proxy constructor after init call ([c38e331](https://github.com/rigoblock/v3-contracts/commit/c38e3315084232a0084c71bf39a6e3596f15519e))
* fix GRG token overrides ([05c4f2e](https://github.com/rigoblock/v3-contracts/commit/05c4f2ed5427092728a82bbbfd3279aaccf050af))
* initialize owner to null in staking to prevent direct calls ([4fdd46d](https://github.com/rigoblock/v3-contracts/commit/4fdd46d8bf85c35e2a023e89afd8b62270653ffb))
* prevent direct staking pool creation in staking ([ba3101f](https://github.com/rigoblock/v3-contracts/commit/ba3101ff7ce9495050140092f4fea0216c752075))
* proxy inherits from own interface for consistency ([dd91970](https://github.com/rigoblock/v3-contracts/commit/dd919706b65bd794f3401e39cf2038f99af12aa0))
* remove deprecated authority extensions contract ([2f9dd55](https://github.com/rigoblock/v3-contracts/commit/2f9dd559841c37da1bed17b696b6675cf5bdccbf))
* remove requirement base token decimals < 18 ([b439d9a](https://github.com/rigoblock/v3-contracts/commit/b439d9a15c587793bf53c38cfbe147b4ab7764a1))
* remove some TODO comments in contracts and improved comments ([e7f5e3f](https://github.com/rigoblock/v3-contracts/commit/e7f5e3f2d35dcdbbe46dc150d2d6307b767fe131))
* removed unused import in storage ([c940ed8](https://github.com/rigoblock/v3-contracts/commit/c940ed8d69b019cce343dac96b9d739f4b49cf78))
* rename AuthorityCore to Authority and update deploy pipeline ([1e39529](https://github.com/rigoblock/v3-contracts/commit/1e39529e8e9040b4a4f8c917195c3ea0d7e8c3d2))
* require address not same when upgrading in factory ([7a43c69](https://github.com/rigoblock/v3-contracts/commit/7a43c695cee843e545c15b87f92ba38d91b6a2a1))
* require approve target is contract in uniswap adapter ([552224a](https://github.com/rigoblock/v3-contracts/commit/552224ab3a25d8dda96155e897abcc134ed62fc2))
* require name shorter than 32 characters ([d70df78](https://github.com/rigoblock/v3-contracts/commit/d70df783bab65a0db4a780cd7e66669e31290b94))
* restrict mint method as non reentrant ([405901c](https://github.com/rigoblock/v3-contracts/commit/405901cac9569801accd5f399389c364f32ba9ef))
* restrict uniswap adapter swap methods to whitelisted tokens ([e72d110](https://github.com/rigoblock/v3-contracts/commit/e72d110b87f23ffd63fcac6dc34f439c462ed05c))
* revert if pool init unsuccessful ([db63fd2](https://github.com/rigoblock/v3-contracts/commit/db63fd255130b1e3cac9f75a4085112de458dc41))
* upgrade contracts to solc v0.8.17 from .0.8.14 ([08062ec](https://github.com/rigoblock/v3-contracts/commit/08062ecb69300c5b660cb40eaa0faf956545c9c5))
* upgrade staking to solc 0.8.17 ([b8cef8a](https://github.com/rigoblock/v3-contracts/commit/b8cef8a229136e134b1d551d8dc50d9a17d78572))


### Features

* add agnostic storage view method in mixin storage accessible ([209cbff](https://github.com/rigoblock/v3-contracts/commit/209cbff46886d6540df88fee9347cf259d2eda65))
* add storage accessible ([3915283](https://github.com/rigoblock/v3-contracts/commit/3915283d31fd50c7d94710a1fa0150ef8ed2165d))
* added whitelist extension ([e752487](https://github.com/rigoblock/v3-contracts/commit/e752487a287749079028493398aba5302c1f1d0b))
* catch error string in proxy factory ([553c56b](https://github.com/rigoblock/v3-contracts/commit/553c56b43864a1e018eae9a719b8d669fac4b0c9))
* token-whitelist ([a6fa264](https://github.com/rigoblock/v3-contracts/commit/a6fa26482394f19760b5a862e1da00c7108a829b))



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



