import { expect } from "chai";
import { network } from "hardhat";
import { encodeBytes32String } from "ethers";
import { getFixedGasSigners } from "../shared/helper";
import { createFixture } from "../utils/fixtures";

describe("ExtensionsMapDeployer", async () => {
  const setupTests = createFixture(["tests-setup"], async ({ get }) => {
    const [user1] = await getFixedGasSigners();
    const { ethers } = await network.getOrCreate();
    const deployer = await ethers.getContractAt(
      "ExtensionsMapDeployer",
      (await get("ExtensionsMapDeployer")).address,
    );
    return {
      deployer,
      user1,
    };
  });

  describe("deployExtensionsMap", async () => {
    it("should not re-deploy if salt has not changed", async () => {
      const { deployer, user1 } = await setupTests();
      const extensions = {
        eApps: user1.address,
        eOracle: user1.address,
        eUpgrade: user1.address,
        eCrosschain: user1.address,
        eNavView: user1.address,
        eGmxCallback: user1.address,
      };
      const wrappedNative = user1.address;
      const params = {
        extensions: extensions,
        wrappedNative: wrappedNative,
      };
      const salt = encodeBytes32String("randomSalt");
      const extensionsMapAddress =
        await deployer.deployExtensionsMap.staticCall(params, salt);
      const tx = await deployer.deployExtensionsMap(params, salt);
      await tx.wait();
      const newExtensionsMapAddress =
        await deployer.deployExtensionsMap.staticCall(params, salt);
      expect(extensionsMapAddress).to.be.eq(newExtensionsMapAddress);
      // try to deploy again with the same salt but different params
      params.extensions.eApps = user1.address;
      const newExtensionsMapAddress2 =
        await deployer.deployExtensionsMap.staticCall(params, salt);
      expect(extensionsMapAddress).to.be.eq(newExtensionsMapAddress2);
    });

    // This test asserts that we can deploy to the same address on all chains
    it("should re-deploy if params are same but salt has changed", async () => {
      const { deployer, user1 } = await setupTests();
      const extensions = {
        eApps: user1.address,
        eOracle: user1.address,
        eUpgrade: user1.address,
        eCrosschain: user1.address,
        eNavView: user1.address,
        eGmxCallback: user1.address,
      };
      const wrappedNative = user1.address;
      const params = {
        extensions: extensions,
        wrappedNative: wrappedNative,
      };
      let salt = encodeBytes32String("randomSalt");
      const extensionsMapAddress =
        await deployer.deployExtensionsMap.staticCall(params, salt);
      const tx = await deployer.deployExtensionsMap(params, salt);
      await tx.wait();
      salt = encodeBytes32String("randomSalt2");
      const newExtensionsMapAddress =
        await deployer.deployExtensionsMap.staticCall(params, salt);
      expect(extensionsMapAddress).to.be.not.eq(newExtensionsMapAddress);
    });
  });
});
