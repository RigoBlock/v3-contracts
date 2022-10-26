import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  /*const grgTransferProxy = await deploy("ERC20Proxy", {
    from: deployer,
    args: [deployer],  // Authorizable(_owner)
    log: true,
    deterministicDeployment: true,
  });*/
  const grgTransferProxy = {address: "0x8C96182c1B2FE5c49b1bc9d9e039e369f131ED37"}

  /*const rigoToken = await deploy("RigoToken", {
    from: deployer,
    args: [
      deployer, // address _setMinter
      deployer, // address _setRigoblock
      deployer // address _grgHolder
    ],
    log: true,
    deterministicDeployment: true,
  });*/
  const rigoToken = {address: "0x4FbB350052Bca5417566f188eB2EBCE5b19BC964"}

  /*const grgVault = await deploy("GrgVault", {
    from: deployer,
    args: [
        grgTransferProxy.address,
        rigoToken.address,
        deployer  // Authorizable(_owner)
    ],
    log: true,
    deterministicDeployment: true,
  });*/
  const grgVault = {address: "0xfbd2588b170Ff776eBb1aBbB58C0fbE3ffFe1931"}

  const authority = await deploy("Authority", {
    from: deployer,
    args: [deployer],
    log: true,
    deterministicDeployment: true,
  });

  const registry = await deploy("PoolRegistry", {
    from: deployer,
    args: [
      authority.address,
      deployer  // Rigoblock Dao
    ],
    log: true,
    deterministicDeployment: true,
  });

  const staking = await deploy("Staking", {
    from: deployer,
    args: [
        grgVault.address,
        registry.address,
        rigoToken.address,
    ],
    log: true,
    deterministicDeployment: true,
  });

  /*const stakingProxy = await deploy("StakingProxy", {
    from: deployer,
    args: [
        staking.address,
        deployer  // Authorizable(_owner)
    ],
    log: true,
    deterministicDeployment: true,
  });*/
  const stakingProxy = {address: "0x730dDf7b602dB822043e0409d8926440395e07fE"}

  await deploy("AStaking", {
    from: deployer,
    args: [
        stakingProxy.address,
        rigoToken.address,
        grgTransferProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  await deploy("ASelfCustody", {
    from: deployer,
    args: [
        grgVault.address,
        stakingProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  })

  /*const inflation = await deploy("Inflation", {
    from: deployer,
    args: [
      rigoToken.address,
      stakingProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  });*/

  await deploy("ProofOfPerformance", {
    from: deployer,
    args: [stakingProxy.address],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['staking', 'l2-suite', 'main-suite']
export default deploy;
