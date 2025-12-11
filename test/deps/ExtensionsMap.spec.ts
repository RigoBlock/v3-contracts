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
        it('should not re-deploy if salt has not changed', async () => {
            const { deployer } = await setupTests()
            const extensions = {eApps: user1.address, eOracle: user1.address, eUpgrade: user1.address, eAcrossHandler: user1.address}
            const wrappedNative = user1.address
            const params = {
                extensions: extensions,
                wrappedNative: wrappedNative
            }
            const salt = hre.ethers.utils.formatBytes32String("randomSalt");
            const extensionsMapAddress = await deployer.callStatic.deployExtensionsMap(params, salt)
            const tx = await deployer.deployExtensionsMap(params, salt)
            await tx.wait();
            const newExtensionsMapAddress = await deployer.callStatic.deployExtensionsMap(params, salt)
            expect(extensionsMapAddress).to.be.eq(newExtensionsMapAddress)
            // try to deploy again with the same salt but different params
            params.extensions.eApps = user1.address
            const newExtensionsMapAddress2 = await deployer.callStatic.deployExtensionsMap(params, salt)
            expect(extensionsMapAddress).to.be.eq(newExtensionsMapAddress2)
        })

        // This test asserts that we can deploy to the same address on all chains
        it('should re-deploy if params are same but salt has changed', async () => {
            const { deployer } = await setupTests()
            const extensions = {eApps: user1.address, eOracle: user1.address, eUpgrade: user1.address, eAcrossHandler: user1.address}
            const wrappedNative = user1.address
            const params = {
                extensions: extensions,
                wrappedNative: wrappedNative
            }
            let salt = hre.ethers.utils.formatBytes32String("randomSalt");
            const extensionsMapAddress = await deployer.callStatic.deployExtensionsMap(params, salt)
            const tx = await deployer.deployExtensionsMap(params, salt)
            await tx.wait();
            salt = hre.ethers.utils.formatBytes32String("randomSalt2");
            const newExtensionsMapAddress = await deployer.callStatic.deployExtensionsMap(params, salt)
            expect(extensionsMapAddress).to.be.not.eq(newExtensionsMapAddress)
        })
    })
})