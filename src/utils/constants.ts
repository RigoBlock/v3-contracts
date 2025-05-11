export const AddressOne = "0x0000000000000000000000000000000000000001";

interface ChainConfig {
    rigoToken: string;
    oracle: string;
    stakingProxy: string;
    weth: string;
    uniswapRouter2: string;
    univ3Npm: string;
    univ4Posm: string;
    universalRouter: string;
}

// Chain-specific configuration
export const chainConfig: { [chainId: number]: ChainConfig } = {
    // Ethereum Mainnet (Chain ID: 1)
    1: {
        rigoToken: "0x4FbB350052Bca5417566f188eB2EBCE5b19BC964",
        oracle: "0xB13250f0Dc8ec6dE297E81CDA8142DB51860BaC4",
        stakingProxy: "0x73f92F71544578BCC1D9F3B7dfce18859Bc20261",
        weth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        uniswapRouter2: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
        univ3Npm: "0xC36442b4a4522E871399CD717aBDD847Ab11FE88",
        univ4Posm: "0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e",
        universalRouter: "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af",
    },
    // Arbitrum (Chain ID: 42161)
    42161: {
      rigoToken: "0x7F4638A58C0615037deCc86f1daE60E55fE92874",
      oracle: "0x3043e182047F8696dFE483535785ed1C3681baC4",
      stakingProxy: "0xD495296510257DAdf0d74846a8307bf533a0fB48",
      weth: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
      uniswapRouter2: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
      univ3Npm: "0xC36442b4a4522E871399CD717aBDD847Ab11FE88",
      univ4Posm: "0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869",
      universalRouter: "0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3",
    },
    // Optimism (Chain ID: 10)
    10: {
      rigoToken: "0xEcF46257ed31c329F204Eb43E254C609dee143B3",
      oracle: "0x79234983dED8EAA571873fffe94e437e11C7FaC4",
      stakingProxy: "0xB844bDCC64a748fDC8c9Ee74FA4812E4BC28FD70",
      weth: "0x4200000000000000000000000000000000000006",
      uniswapRouter2: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
      univ3Npm: "0xC36442b4a4522E871399CD717aBDD847Ab11FE88",
      univ4Posm: "0x3C3Ea4B57a46241e54610e5f022E5c45859A1017",
      universalRouter: "0x851116D9223fabED8E56C0E6b8Ad0c31d98B3507",
    },
    // Polygon (Chain ID: 137)
    137: {
      rigoToken: "0xBC0BEA8E634ec838a2a45F8A43E7E16Cd2a8BA99",
      oracle: "0x1D8691A1A7d53B60DeDd99D8079E026cB0E5bac4",
      stakingProxy: "0xC87d1B952303ae3A9218727692BAda6723662dad",
      weth: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270",
      uniswapRouter2: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
      univ3Npm: "0xC36442b4a4522E871399CD717aBDD847Ab11FE88",
      univ4Posm: "0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9",
      universalRouter: "0x1095692A6237d83C6a72F3F5eFEdb9A670C49223",
    },
    // BSC (Chain ID: 56)
    56: {
      rigoToken: "0x3d473C3eF4Cd4C909b020f48477a2EE2617A8e3C",
      oracle: "0x77B2051204306786934BE8bEC29a48584E133aC4",
      stakingProxy: "0xa4a94cCACa8ccCdbCD442CF8eECa0cd98f69e99e",
      weth: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c",
      uniswapRouter2: "0xB971eF87ede563556b2ED4b1C0b0019111Dd85d2",
      univ3Npm: "0x7b8A01B39D58278b5DE7e48c8449c9f4F5170613",
      univ4Posm: "0x7A4a5c919aE2541AeD11041A1AEeE68f1287f95b",
      universalRouter: "0x1906c1d672b88cD1B9aC7593301cA990F94Eae07",
    },
    // Unichain (Chain ID: 130)
    130: {
        rigoToken: "0x03C2868c6D7fD27575426f395EE081498B1120dd",
        oracle: "0x54bd666eA7FD8d5404c0593Eab3Dcf9b6E2A3aC4",
        stakingProxy: "0x550Ed0bFFdbE38e8Bd33446D5c165668Ea071643",
        weth: "0x4200000000000000000000000000000000000006",
        uniswapRouter2: "NA", // Uniswap Router 2 not available on Unichain, should pass weth instead, as unused otherwise
        univ3Npm: "0x943e6e07a7E8E791dAFC44083e54041D743C46E9",
        univ4Posm: "0x4529A01c7A0410167c5740C487A8DE60232617bf",
        universalRouter: "0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3",
    },
    // Base (Chain ID: 8453)
    8453: {
        rigoToken: "0x09188484e1Ab980DAeF53a9755241D759C5B7d60",
        oracle: "0x59f39091Fd6f47e9D0bCB466F74e305f1709BAC4", 
        stakingProxy: "0xc758Ea84d6D978fe86Ee29c1fbD47B4F302F1992",
        weth: "0x4200000000000000000000000000000000000006",
        uniswapRouter2: "0x2626664c2603336E57B271c5C0b26F421741e481",
        univ3Npm: "0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1",
        univ4Posm: "0x7C5f5A4bBd8fD63184577525326123B519429bDc",
        universalRouter: "0x6fF5693b99212Da76ad316178A184AB56D299b43",
    },
    // Sepolia (Chain ID: 11155111)
    11155111: {
        rigoToken: "0x076C619e7ebaBe40746106B66bFBed731F2c1339",
        oracle: "0xE39CAf28BF7C238A42D4CDffB96587862F41bAC4", 
        stakingProxy: "0xD40edcc947fF35637233d765CB9efCFc10fC8c22",
        weth: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
        uniswapRouter2: "0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E",
        univ3Npm: "0x1238536071E1c677A632429e3655c799b22cDA52",
        univ4Posm: "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4",
        universalRouter: "0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b",
    },
};
