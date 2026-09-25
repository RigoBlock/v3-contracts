import { expect } from "chai";
import { network } from "hardhat";
import { parseEther } from "ethers";

describe("TestFixedMath", async () => {
  describe("mul", async () => {
    it("should overflow with error", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const overflowAmount = 2n ** 200n;
      await expect(
        testFixedMath.mul(overflowAmount, overflowAmount),
      ).to.be.revertedWith("MULTIPLICATION_OVERFLOW_ERROR");
    });
  });

  describe("div", async () => {
    it("should revert if dividing by 0", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const amount = 2n ** 20n;
      await expect(testFixedMath.div(amount, 0)).to.be.revertedWith(
        "DIVISION_BY_ZERO_ERROR",
      );
    });

    it("should overflow with error", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const minFidedValue = -(2n ** 255n);
      await expect(testFixedMath.div(minFidedValue, -1))
        // won't overflow division as will overflow mul op first
        //.to.be.revertedWith("DIVISION_OVERFLOW_ERROR")
        .to.be.revertedWith("MULTIPLICATION_OVERFLOW_ERROR");
    });
  });

  describe("muldiv", async () => {
    it("should overflow with error", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const minFidedValue = -(2n ** 255n) / 2n;
      await expect(
        testFixedMath.mulDiv(minFidedValue, 2, -1),
      ).to.be.revertedWith("DIVISION_OVERFLOW_ERROR");
    });
  });

  describe("ln", async () => {
    it("should overflow with error", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      await expect(testFixedMath.ln(-50)).to.be.revertedWith(
        "X_TOO_SMALL_ERROR",
      );
    });

    it("should revert with min exp value", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const minExpValue = -(2n ** 255n);
      await expect(testFixedMath.ln(minExpValue)).to.be.revertedWith(
        "X_TOO_SMALL_ERROR",
      );
    });

    it("reverts with big x", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      // reverts with lower than expected numbers, prob due to decimals required
      const maxInt = 2n ** 128n - 2n;
      await expect(testFixedMath.ln(maxInt)).to.be.revertedWith(
        "X_TOO_LARGE_ERROR",
      );
    });

    it("should return log", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      let ln;
      ln = await testFixedMath.ln(parseEther("1.05"));
      expect(ln).to.be.lt(0);
      ln = await testFixedMath.ln(parseEther("0.73"));
      expect(ln).to.be.lt(0);
      ln = await testFixedMath.ln(parseEther("0.21"));
      ln = await testFixedMath.ln(parseEther("1.065"));
      ln = await testFixedMath.ln(parseEther("0.36"));
      ln = await testFixedMath.ln(parseEther("0.99"));
      const firstThreshold = 2154696114062189943324672n;
      ln = await testFixedMath.ln(firstThreshold);
      expect(ln).to.be.lt(0);
    });

    it("returns min ln", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const lnMinVal = 30920707162n;
      const expMinVal = -10867768093537472176861526524852097253376n;
      const minLn = await testFixedMath.ln(lnMinVal);
      const ln = await testFixedMath.ln(lnMinVal - 1n);
      expect(ln).to.be.eq(minLn);
      expect(ln).to.be.eq(expMinVal);
      await testFixedMath.ln(lnMinVal + 1n);
    });
  });

  describe("exp", async () => {
    it("reverts with large number", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      await testFixedMath.exp(-50);
      await expect(testFixedMath.exp(2)).to.be.revertedWith(
        "X_TOO_LARGE_ERROR",
      );
    });

    it("runs exponent", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const expMinVal = -10867768093537472176861526524852097253376n;
      let value;
      value = await testFixedMath.exp(expMinVal - 1n);
      expect(value).to.be.eq(0n);
      value = await testFixedMath.exp(expMinVal);
      expect(value).to.be.not.eq(0n);
      await testFixedMath.exp(-10866000000000000000000n);
      await testFixedMath.exp(-32);
      await testFixedMath.exp(-16);
    });
  });

  describe("uintMul", async () => {
    it("runs exponent", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      await testFixedMath.uintMul(-50, 60);
    });

    it("reverts with big u", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const maxUint = 2n ** 255n;
      await expect(testFixedMath.uintMul(-50, maxUint)).to.be.revertedWith(
        "U_TOO_LARGE_ERROR",
      );
    });
  });

  describe("toFixed", async () => {
    it("runs exponent", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      await testFixedMath.toFixed(40, 50);
    });

    it("reverts with big n", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const maxUint = 2n ** 255n;
      await expect(testFixedMath.toFixed(maxUint, 2)).to.be.revertedWith(
        "N_TOO_LARGE_ERROR",
      );
    });

    it("reverts with big d", async () => {
      const { ethers } = await network.getOrCreate();
      const testFixedMath = await ethers.deployContract("TestLibFixedMath");
      const maxUint = 2n ** 255n;
      await expect(testFixedMath.toFixed(2, maxUint)).to.be.revertedWith(
        "D_TOO_LARGE_ERROR",
      );
    });
  });
});
