import { expect } from "chai";
import hre, { deployments, waffle } from "hardhat";
import "@nomiclabs/hardhat-ethers";

describe("ExtensionsMapDeployer", async () => {
    const [ user1 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const ExtensionsMapDeployerInstance = await deployments.get("ExtensionsMapDeployer")
        const ExtensionsMapDeployer = await hre.ethers.getContractFactory("ExtensionsMapDeployer")
        return {
            deployer: ExtensionsMapDeployer.attach(ExtensionsMapDeployerInstance.address),
        }
    });

    describe("deployExtensionsMap", async () => {
        it('should not re-deploy if params have not changed', async () => {
            const { deployer } = await setupTests()
            const extensions = {eApps: user1.address, eOracle: user1.address, eUpgrade: user1.address}
            const wrappedNative = user1.address
            const params = {
                extensions: extensions,
                wrappedNative: wrappedNative
            }
            const extensionsMapAddress = await deployer.callStatic.deployExtensionsMap(params)
            const tx = await deployer.deployExtensionsMap(params)
            await tx.wait();
            const newExtensionsMapAddress = await deployer.callStatic.deployExtensionsMap(params)
            expect(extensionsMapAddress).to.be.eq(newExtensionsMapAddress)
        })
    })
})