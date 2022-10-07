import { expect } from "chai";
import hre, { deployments, waffle, ethers } from "hardhat";
import "@nomiclabs/hardhat-ethers";
import { AddressZero } from "@ethersproject/constants";
import { parseEther } from "@ethersproject/units";
import { getAddress } from "ethers/lib/utils";
import { utils } from "ethers";
import { deployContract, timeTravel } from "../utils/utils";

describe("ReentrancyGuard", async () => {
    const [ user1, user2, user3 ] = waffle.provider.getWallets()

    const setupTests = deployments.createFixture(async ({ deployments }) => {
        await deployments.fixture('tests-setup')
        const RigoblockPoolProxyFactory = await deployments.get("RigoblockPoolProxyFactory")
        const Factory = await hre.ethers.getContractFactory("RigoblockPoolProxyFactory")
        return {
            factory: Factory.attach(RigoblockPoolProxyFactory.address)
        }
    });

    describe("nonReentrant", async () => {
        // The following test produces an effective reentrancy attack, however because the transaction is reverted with error
        // "POOL_TRANSFER_FROM_FAILED_ERROR" when the pool makes a low-level call to the rogue token, we cannot return the
        // expected error "REENTRANCY_ILLEGAL"
        it('should fail when trying to mint', async () => {
            const { factory } = await setupTests()
            const source = `
            contract RogueToken {
                uint256 public totalSupply = 1e24;
                uint8 public decimals = 18;
                address private reentrancyAttack;
                mapping(address => uint256) balances;
                function init(address _reentrancyAttack) public {
                    balances[msg.sender] = totalSupply;
                    reentrancyAttack = _reentrancyAttack;
                }
                function transfer(address to, uint256 amount) public returns (bool success) {
                    balances[to] += amount;
                    balances[msg.sender] -= amount;
                    return true;
                }
                function transferFrom(address from,address to,uint256 amount) public returns (bool success) {
                    balances[to] += amount;
                    balances[from] -= amount;
                    (, bytes memory data) = reentrancyAttack.call(abi.encodeWithSelector(0x1e832ae8));
                    if (data.length != 0) {
                        revert(string(data));
                    }
                    return true;
                }
                function balanceOf(address _who) external view returns (uint256) {
                    return balances[_who];
                }
            }`
            const rogueToken = await deployContract(user1, source)
            const { newPoolAddress } = await factory.callStatic.createPool(
                'testpool',
                'TEST',
                rogueToken.address
            )
            await factory.createPool('testpool', 'TEST', rogueToken.address)
            const PoolInterface = await hre.ethers.getContractFactory("RigoblockV3Pool")
            const pool = PoolInterface.attach(newPoolAddress)
            const TestReentrancyAttack = await hre.ethers.getContractFactory("TestReentrancyAttack")
            const testReentrancyAttack = await TestReentrancyAttack.deploy(newPoolAddress)
            await rogueToken.init(testReentrancyAttack.address)
            const tokenAmount = parseEther("100")
            await rogueToken.transfer(testReentrancyAttack.address, tokenAmount)
            await expect(testReentrancyAttack.mintPool()).to.be.revertedWith("POOL_TRANSFER_FROM_FAILED_ERROR")
            expect(await testReentrancyAttack.count()).to.be.eq(0)
            await testReentrancyAttack.setMaxCount(1)
            await testReentrancyAttack.mintPool()
            expect(await testReentrancyAttack.count()).to.be.eq(2)
            expect(await pool.balanceOf(testReentrancyAttack.address)).to.be.eq(parseEther("9.5"))
            expect(await rogueToken.balanceOf(pool.address)).to.be.eq(parseEther("10"))
        })
    })
})
