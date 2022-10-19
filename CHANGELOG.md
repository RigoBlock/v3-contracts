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



