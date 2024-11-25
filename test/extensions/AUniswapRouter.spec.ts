import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";

describe.skip("AUniswapRouter", function () {
  let aUniswapRouter: Contract;
  let mockUniswapRouter: Contract;
  let mockErc20: Contract;
  let owner: any;
  let addr1: any;

  beforeEach(async function () {
    [owner, addr1] = await ethers.getSigners();

    // Deploy a mock ERC20 token
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockErc20 = await MockERC20.deploy("Mock Token", "MTK", 18, ethers.utils.parseEther("1000"));
    await mockErc20.deployed();

    // Deploy a mock Uniswap Router
    const MockUniswapRouter = await ethers.getContractFactory("MockUniswapRouter");
    mockUniswapRouter = await MockUniswapRouter.deploy();
    await mockUniswapRouter.deployed();

    // Deploy the AUniswapRouter contract
    const AUniswapRouter = await ethers.getContractFactory("AUniswapRouter");
    aUniswapRouter = await AUniswapRouter.deploy(mockUniswapRouter.address, ethers.constants.AddressZero); // Assuming the second parameter is for positionManager which is not mocked here
    await aUniswapRouter.deployed();
  });

  it("should approve tokens before executing and disapprove after", async function () {
    const commands = "0x01"; // Assuming command for swap
    const inputs = ethers.utils.defaultAbiCoder.encode(
      ["address", "uint256", "address", "uint256", "address", "uint256"],
      [mockErc20.address, ethers.utils.parseEther("1"), ethers.constants.AddressZero, 0, owner.address, 0]
    );

    // Transfer some tokens to the contract
    await mockErc20.transfer(aUniswapRouter.address, ethers.utils.parseEther("1"));

    const initialAllowance = await mockErc20.allowance(aUniswapRouter.address, mockUniswapRouter.address);

    // Execute the function
    await aUniswapRouter.execute(commands, [inputs]);

    // Check that tokens were approved
    const approvalAmount = await mockErc20.allowance(aUniswapRouter.address, mockUniswapRouter.address);
    expect(approvalAmount).to.be.gt(initialAllowance);

    // Check that tokens were disapproved after execution
    // Assuming the contract disapproves tokens by setting allowance to 1
    await expect(aUniswapRouter.execute(commands, [inputs])).to.changeTokenBalances(
      mockErc20,
      [aUniswapRouter.address],
      [ethers.utils.parseEther("-1")]
    );
  });

  it("should revert with the correct error message", async function () {
    await mockUniswapRouter.setRevertReason("Test error");

    const commands = "0x01";
    const inputs = ethers.utils.defaultAbiCoder.encode(
      ["address", "uint256", "address", "uint256", "address", "uint256"],
      [mockErc20.address, ethers.utils.parseEther("1"), ethers.constants.AddressZero, 0, owner.address, 0]
    );

    await expect(aUniswapRouter.execute(commands, [inputs]))
      .to.be.revertedWith("Test error");
  });

  it("should revert with the correct return data", async function () {
    await mockUniswapRouter.setRevertData("0x1234");

    const commands = "0x01";
    const inputs = ethers.utils.defaultAbiCoder.encode(
      ["address", "uint256", "address", "uint256", "address", "uint256"],
      [mockErc20.address, ethers.utils.parseEther("1"), ethers.constants.AddressZero, 0, owner.address, 0]
    );

    await expect(aUniswapRouter.execute(commands, [inputs]))
      .to.be.revertedWithCustomError(mockUniswapRouter, "RevertWithData");
  });

  it("should handle a deadline", async function () {
    const commands = "0x01";
    const inputs = ethers.utils.defaultAbiCoder.encode(
      ["address", "uint256", "address", "uint256", "address", "uint256", "uint256"],
      [mockErc20.address, ethers.utils.parseEther("1"), ethers.constants.AddressZero, 0, owner.address, 0, Math.floor(Date.now() / 1000) + 3600] // deadline 1 hour from now
    );

    // Should pass as the deadline has not been reached
    await expect(aUniswapRouter.execute(commands, [inputs], Math.floor(Date.now() / 1000) + 3600)).not.to.be.reverted;

    // Should revert when the deadline has passed
    await expect(aUniswapRouter.execute(commands, [inputs], Math.floor(Date.now() / 1000) - 100))
      .to.be.revertedWithCustomError(aUniswapRouter, "TransactionDeadlinePassed");
  });

  it("should handle nested sub-plans", async function () {
    const commands = "0x0201"; // EXECUTE_SUB_PLAN followed by a swap command
    const subCommands = "0x01"; // A simple swap command
    const inputs = ethers.utils.defaultAbiCoder.encode(
      ["bytes", "bytes[]"],
      [
        subCommands,
        [ethers.utils.defaultAbiCoder.encode(
          ["address", "uint256", "address", "uint256", "address", "uint256"],
          [mockErc20.address, ethers.utils.parseEther("1"), ethers.constants.AddressZero, 0, owner.address, 0]
        )]
      ]
    );

    await expect(aUniswapRouter.execute(commands, [inputs]))
      .to.emit(mockUniswapRouter, "Execute");
  });

  // Add more tests as needed for other functionalities like token whitelist checks, recipient validation, etc.
});