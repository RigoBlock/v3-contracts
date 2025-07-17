import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  // TODO: on each network it is different, change as deploying on other chains
  // mainnet: 0x730dDf7b602dB822043e0409d8926440395e07fE
  // goerli: 0x6C4594aa0CBcb8315E88EFdb11675c09A7a5f444
  // arbitrum: 0xD495296510257DAdf0d74846a8307bf533a0fB48
  // optimism: 0xB844bDCC64a748fDC8c9Ee74FA4812E4BC28FD70
  // polygon: 0xC87d1B952303ae3A9218727692BAda6723662dad
  // bsc: 0xa4a94cCACa8ccCdbCD442CF8eECa0cd98f69e99e
  // unichain: 0x550Ed0bFFdbE38e8Bd33446D5c165668Ea071643
  const stakingProxy = {address: "0x550Ed0bFFdbE38e8Bd33446D5c165668Ea071643"};

  await deploy("RigoblockGovernanceFactory", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("RigoblockGovernance", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("RigoblockGovernanceStrategy", {
    from: deployer,
    args: [stakingProxy.address],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['governance', 'l2-suite', 'main-suite']
export default deploy;