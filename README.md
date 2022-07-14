# v3-contracts
Smart contracts of RigoBlock v3
=====================

[![npm version](https://badge.fury.io/js/@rgbk%2Fv3-contracts.svg)](https://badge.fury.io/js/@rgbk%2Fv3-contracts)
[![Build Status](https://github.com/rigoblock/v3-contracts/workflows/v3-contracts/badge.svg?branch=development)](https://github.com/rigoblock/v3-contracts/actions)
[![Coverage Status](https://coveralls.io/repos/github/RigoBlock/v3-contracts/badge.svg?branch=development)](https://coveralls.io/github/RigoBlock/v3-contracts)


Usage
-----
### Install requirements with yarn:

```bash
yarn
```

### Run all tests:

```bash
yarn build
yarn test
```

### storage upgrades
New storage variables in the implementation must be added to a dedicated storage to prevent storage collision.

### Commit format:
PR must follow "Conventional Commits spec". PR title is checked upon opening. Examples for valid PR titles:

- ```fix```: Correct typo. (patch)
- ```feat```: Add support for ... (minor)
- ```refactor!```: Drop support for ... (major)

 Other PR titles are also valid:

- ```build:```,```chore:```,```ci:```,```docs:```,```style:```,```refactor:```,```perf:```,```test:```

### License
All smart contracts are released under Apache-2.0
