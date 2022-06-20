import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { AddressZero } from "@ethersproject/constants"

const deploy: DeployFunction = async function (
  hre: HardhatRuntimeEnvironment,
) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();
  const { deploy } = deployments;

  const authority = await deploy("Authority", {
    from: deployer,
    args: [deployer], // owner
    log: true,
    deterministicDeployment: true,
  });

  const authorityInstance = await hre.ethers.getContractAt(
    "Authority",
    authority.address
  );
/*
  // TODO: follwing returns cannot find artifact "ExchangesAuthority"
  // probably due to naming or position of file
  const exchangesAuthority = await deploy("ExchangesAuthority", {
    from: deployer,
    args: [deployer], // owner
    log: true,
    deterministicDeployment: true
  });

  const exchangesAuthorityInstance = hre.ethers.getContractAt(
    "ExchangesAuthority",
    exchangesAuthority.address
  );

  //await authorityInstance.setExchangesAuthority(exchangesAuthority.address);
  //await exchangesAuthority.setWhitelister(deployer)
*/
  const registry = await deploy("DragoRegistry", {
    from: deployer,
    args: [authority.address],
    log: true,
    deterministicDeployment: true,
  });

  const proxyFactory = await deploy("RigoblockPoolProxyFactory", {
    from: deployer,
    args: [
      registry.address,
      deployer, // address _dragoDao
      authority.address,
      deployer  // address _owner
    ],
    log: true,
    deterministicDeployment: true,
  });

  await authorityInstance.whitelistFactory(proxyFactory.address, true)

  const rigoToken = await deploy("RigoToken", {
    from: deployer,
    args: [
      deployer, // address _setMinter
      deployer  // address _setRigoblock
    ],
    log: true,
    deterministicDeployment: true,
  });

  const rigoTokenInstance = await hre.ethers.getContractAt(
    "RigoToken",
    rigoToken.address
  );

  const navVerifier = await deploy("NavVerifier", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  await authorityInstance.setNavVerifier(navVerifier.address)
/*
  const sigVerifier = await deploy("SigVerifier", {
    from: deployer,
    args: [rigoToken.address],
    log: true,
    deterministicDeployment: true,
  });

  await exchangesAuthority.setSignatureVerifier(sigVerifier.address)
*/
  // TODO: deploy Tokentransferproxy

  await deploy("GrgVault", {
    from: deployer,
    args: [
      deployer, // mock grg transfer proxy address
      rigoToken.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  const staking = await deploy("Staking", {
    from: deployer,
    args: [],
    log: true,
    deterministicDeployment: true,
  });

  const stakingProxy = await deploy("StakingProxy", {
    from: deployer,
    args: [staking.address],
    log: true,
    deterministicDeployment: true,
  });

  const inflation = await deploy("Inflation", {
    from: deployer,
    args: [
      rigoToken.address,
      stakingProxy.address
    ],
    log: true,
    deterministicDeployment: true,
  });

  await rigoTokenInstance.changeMintingAddress(inflation.address)
  await rigoTokenInstance.changeRigoblockAddress(AddressZero)

  await deploy("ProofOfPerformance", {
    from: deployer,
    args: [
      stakingProxy.address,
      deployer, // address _rigoblockDao
      registry.address,
      authority.address
    ],
    log: true,
    deterministicDeployment: true,
  });
};

deploy.tags = ['tests-setup', 'l2-suite', 'main-suite']
export default deploy;
