import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";

describe("AUniswapRouter", function () {
  let aUniswapRouter: Contract;
  let mockUniswapRouter: Contract;
  let owner: any;
  let addr1: any;
  let tokensIn: string[];
  let tokensOut: string[];
  let commands: string;
  let inputs: string;

  beforeEach(async function () {
    [owner, addr1] = await ethers.getSigners();

    // Deploy a mock Uniswap Router
    const MockUniswapRouter = await ethers.getContractFactory("MockUniswapRouter");
    mockUniswapRouter = await MockUniswapRouter.deploy();
    await mockUniswapRouter.deployed();

    // Deploy the AUniswapRouter contract
    const AUniswapRouter = await ethers.getContractFactory("AUniswapRouter");
    aUniswapRouter = await AUniswapRouter.deploy(mockUniswapRouter.address);
    await aUniswapRouter.deployed();

    // Initialize test variables
    tokensIn = [ethers.constants.AddressZero];
    tokensOut = [ethers.constants.AddressZero];
    commands = "0x";
    inputs = "0x";
  });

  it("should approve tokens and execute the Uniswap router", async function () {
    await expect(aUniswapRouter.execute(commands, inputs))
      .to.emit(mockUniswapRouter, "Execute")
      .withArgs(commands, inputs);

    // Check that tokens were approved
    for (const token of tokensIn) {
      expect(await aUniswapRouter.allowance(token, mockUniswapRouter.address)).to.equal(ethers.constants.MaxUint256);
    }

    // Check that tokens were disapproved
    for (const token of tokensIn) {
      expect(await aUniswapRouter.allowance(token, mockUniswapRouter.address)).to.equal(1);
    }
  });

  it("should revert with the correct error message", async function () {
    await mockUniswapRouter.setRevertReason("Test error");

    await expect(aUniswapRouter.execute(commands, inputs))
      .to.be.revertedWith("Test error");
  });

  it("should revert with the correct return data", async function () {
    await mockUniswapRouter.setRevertData("0x1234");

    await expect(aUniswapRouter.execute(commands, inputs))
      .to.be.revertedWith("0x1234");
  });
});