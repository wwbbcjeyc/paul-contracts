import { expect } from "chai";
import { network } from "hardhat";

describe("PaulToken", function () {
  let ethers: any;
  let signers: any[];
  
  // 在所有测试之前建立连接
  before(async () => {
    const connection = await network.connect();
    ethers = connection.ethers;
    signers = await ethers.getSigners();
  });
  
  // 部署夹具 - 每个测试独立部署，避免相互影响
  async function deployPaulTokenFixture() {
    const [owner, account1, account2, rewardPoolAccount] = signers;
    
    const PaulToken = await ethers.getContractFactory("PaulToken");
    const paulToken = await PaulToken.deploy(rewardPoolAccount.address);
    await paulToken.waitForDeployment();
    
    return { paulToken, owner, account1, account2, rewardPool: rewardPoolAccount };
  }
  
  // 辅助函数：增加时间
  async function increaseTime(seconds: number) {
    await ethers.provider.send("evm_increaseTime", [seconds]);
    await ethers.provider.send("evm_mine", []);
  }
  
  // 代币常量
  const TOKEN_NAME = "PaulToken";
  const TOKEN_SYMBOL = "TBD";
  const TOKEN_DECIMALS = 18;
  const ONE_DAY = 86400;
  const INITIAL_SUPPLY = 100000000000n * 10n ** 18n; // 1000亿
  const TARGET_SUPPLY = 21000000n * 10n ** 18n; // 2100万
  const MAX_SUPPLY = 1000000000000n * 10n ** 18n; // 1万亿
  const BURN_PERCENT = 2; // 2%
  const BURN_RESERVE = 1000n * 10n ** 18n; // 1000个代币
  
  describe("部署和初始化", function () {
    it("应该正确部署合约", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      expect(paulToken.target).to.be.properAddress;
    });
    
    it("应该正确设置代币名称和符号", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      expect(await paulToken.name()).to.equal(TOKEN_NAME);
      expect(await paulToken.symbol()).to.equal(TOKEN_SYMBOL);
    });
    
    it("应该正确设置小数位数", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      expect(await paulToken.decimals()).to.equal(TOKEN_DECIMALS);
    });
    
    it("应该正确铸造初始供应量", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const totalSupply = await paulToken.totalSupply();
      const expectedSupply = INITIAL_SUPPLY + BURN_RESERVE;
      expect(totalSupply).to.equal(expectedSupply);
    });
    
    it("应该将初始代币铸造给 owner", async function () {
      const { paulToken, owner } = await deployPaulTokenFixture();
      const ownerBalance = await paulToken.balanceOf(owner.address);
      expect(ownerBalance).to.equal(INITIAL_SUPPLY + BURN_RESERVE);
    });
    
    it("应该正确设置奖励池地址", async function () {
      const { paulToken, rewardPool } = await deployPaulTokenFixture();
      expect(await paulToken.rewardPool()).to.equal(rewardPool.address);
    });
    
    it("应该正确设置销毁储备金", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      expect(await paulToken.burnReserve()).to.equal(BURN_RESERVE);
    });
    
    it("应该正确设置初始销毁时间", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const lastBurnTime = await paulToken.lastBurnTime();
      const currentTime = Math.floor(Date.now() / 1000);
      expect(Number(lastBurnTime)).to.be.closeTo(currentTime, 10);
    });
    
    it("应该默认启用销毁功能", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      expect(await paulToken.burnEnabled()).to.be.true;
    });
    
    it("应该默认未停止销毁", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      expect(await paulToken.burnStopped()).to.be.false;
    });
    
    it("应该正确设置目标供应量", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      expect(await paulToken.TARGET_SUPPLY()).to.equal(TARGET_SUPPLY);
    });
  });
  
  describe("销毁功能测试", function () {
    it("应该正确计算可销毁金额", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      await increaseTime(ONE_DAY);
      
      const totalSupply = await paulToken.totalSupply();
      const expectedBurnAmount = (totalSupply * BigInt(BURN_PERCENT)) / 100n;
      const expectedBurnToZero = (expectedBurnAmount * 50n) / 100n;
      const expectedBurnToReward = (expectedBurnAmount * 50n) / 100n;
      
      const [burnToZero, burnToReward] = await paulToken.getBurnableAmounts();
      expect(burnToZero).to.equal(expectedBurnToZero);
      expect(burnToReward).to.equal(expectedBurnToReward);
    });
    
    it("应该成功执行销毁", async function () {
      const { paulToken, owner, rewardPool } = await deployPaulTokenFixture();
      await increaseTime(ONE_DAY);
      
      const totalSupplyBefore = await paulToken.totalSupply();
      const burnAmount = (totalSupplyBefore * BigInt(BURN_PERCENT)) / 100n;
      const burnToReward = (burnAmount * 50n) / 100n;
      
      const ownerBalanceBefore = await paulToken.balanceOf(owner.address);
      const rewardPoolBalanceBefore = await paulToken.balanceOf(rewardPool.address);
      const burnReserveBefore = await paulToken.burnReserve();
      
      await paulToken.executeBurn();
      
      const totalSupplyAfter = await paulToken.totalSupply();
      const ownerBalanceAfter = await paulToken.balanceOf(owner.address);
      const rewardPoolBalanceAfter = await paulToken.balanceOf(rewardPool.address);
      const burnReserveAfter = await paulToken.burnReserve();
      
      expect(totalSupplyAfter).to.equal(totalSupplyBefore - burnAmount);
      expect(ownerBalanceAfter).to.equal(ownerBalanceBefore - burnAmount);
      expect(rewardPoolBalanceAfter).to.equal(rewardPoolBalanceBefore + burnToReward);
      expect(burnReserveAfter).to.equal(burnReserveBefore - burnAmount);
    });
    
    it("应该正确更新销毁统计", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      await increaseTime(ONE_DAY);
      
      const totalSupplyBefore = await paulToken.totalSupply();
      const burnAmount = (totalSupplyBefore * BigInt(BURN_PERCENT)) / 100n;
      const burnToZero = (burnAmount * 50n) / 100n;
      const burnToReward = (burnAmount * 50n) / 100n;
      
      await paulToken.executeBurn();
      
      expect(await paulToken.totalBurned()).to.equal(burnAmount);
      expect(await paulToken.totalBurnedToZero()).to.equal(burnToZero);
      expect(await paulToken.totalSentToRewardPool()).to.equal(burnToReward);
    });
    
    it("应该触发 BurnExecuted 事件", async function () {
      const { paulToken, owner } = await deployPaulTokenFixture();
      await increaseTime(ONE_DAY);
      
      const totalSupplyBefore = await paulToken.totalSupply();
      const burnAmount = (totalSupplyBefore * BigInt(BURN_PERCENT)) / 100n;
      const burnToZero = (burnAmount * 50n) / 100n;
      const burnToReward = (burnAmount * 50n) / 100n;
      
      await expect(paulToken.executeBurn())
        .to.emit(paulToken, "BurnExecuted")
        .withArgs(
          owner.address,
          burnAmount,
          burnToZero,
          burnToReward,
          totalSupplyBefore - burnAmount,
          (value: bigint) => value > 0n
        );
    });
    
    it("不能在24小时内重复销毁", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      await increaseTime(ONE_DAY);
      
      // 执行第一次销毁
      await paulToken.executeBurn();
      
      // 立即尝试第二次销毁，应该失败（还没过24小时）
      await expect(paulToken.executeBurn()).to.be.revertedWith(
        "PaulToken: cannot execute burn yet, 24h cooldown required"
      );
    });
    
    it("不能在销毁功能禁用时执行", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      await increaseTime(ONE_DAY);
      
      await paulToken.toggleBurn(false);
      
      await expect(paulToken.executeBurn()).to.be.revertedWith(
        "PaulToken: burn function is disabled"
      );
    });
    
    it("部署后24小时内不能执行销毁", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      // 不增加时间，直接尝试销毁，应该失败
      await expect(paulToken.executeBurn()).to.be.revertedWith(
        "PaulToken: cannot execute burn yet, 24h cooldown required"
      );
    });
    
    it("销毁储备金不足时应回滚", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      
      // 先补充一些储备金，确保能执行多次销毁
      const replenishAmount = ethers.parseUnits("10000", TOKEN_DECIMALS);
      await paulToken.replenishBurnReserve(replenishAmount);
      await increaseTime(ONE_DAY);
      
      // 执行多次销毁直到储备金不足
      for (let i = 0; i < 10; i++) {
        try {
          await paulToken.executeBurn();
          await increaseTime(ONE_DAY);
        } catch (error: any) {
          // 如果已经不足，跳出循环
          if (error.message.includes("insufficient burn reserve")) {
            break;
          }
          throw error;
        }
      }
      
      // 再次尝试应该失败
      await increaseTime(ONE_DAY);
      await expect(paulToken.executeBurn()).to.be.revertedWith(
        "PaulToken: insufficient burn reserve"
      );
    });
  });
  
  describe("目标供应量停止销毁测试", function () {
    it("应该在达到目标供应量时自动停止销毁", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      
      // 补充足够的储备金以完成整个通缩过程
      const neededReserve = ethers.parseUnits("1000000000", TOKEN_DECIMALS);
      await paulToken.replenishBurnReserve(neededReserve);
      await increaseTime(ONE_DAY);
      
      let currentSupply = await paulToken.totalSupply();
      let burnCount = 0;
      
      console.log(`\n初始供应量: ${ethers.formatUnits(currentSupply, TOKEN_DECIMALS)}`);
      console.log(`目标供应量: ${ethers.formatUnits(TARGET_SUPPLY, TOKEN_DECIMALS)}`);
      
      // 持续销毁直到接近目标
      while (currentSupply > TARGET_SUPPLY && burnCount < 20) {
        const tx = await paulToken.executeBurn();
        const receipt = await tx.wait();
        burnCount++;
        currentSupply = await paulToken.totalSupply();
        
        console.log(`第 ${burnCount} 次销毁后: ${ethers.formatUnits(currentSupply, TOKEN_DECIMALS)}`);
        
        if (currentSupply <= TARGET_SUPPLY) {
          const event = receipt?.logs.find(
            (log: any) => log.fragment?.name === "BurnStopped"
          );
          expect(event).to.exist;
          break;
        }
        
        await increaseTime(ONE_DAY);
      }
      
      console.log(`执行了 ${burnCount} 次销毁`);
      console.log(`最终供应量: ${ethers.formatUnits(currentSupply, TOKEN_DECIMALS)}`);
      
      expect(currentSupply).to.be.at.most(TARGET_SUPPLY);
      expect(await paulToken.burnStopped()).to.be.true;
      expect(await paulToken.burnEnabled()).to.be.false;
      
      await increaseTime(ONE_DAY);
      await expect(paulToken.executeBurn()).to.be.revertedWith(
        "PaulToken: burn is stopped (target supply reached)"
      );
    });
    
    it("应该在销毁时精确调整金额，确保不低于目标", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      await increaseTime(ONE_DAY);
      
      let currentSupply = await paulToken.totalSupply();
      
      if (currentSupply <= TARGET_SUPPLY) {
        const mintAmount = TARGET_SUPPLY + ethers.parseUnits("1000000", TOKEN_DECIMALS) - currentSupply;
        await paulToken.mint(await paulToken.owner(), mintAmount);
        currentSupply = await paulToken.totalSupply();
      }
      
      const normalBurnAmount = (currentSupply * BigInt(BURN_PERCENT)) / 100n;
      const supplyAfterNormalBurn = currentSupply - normalBurnAmount;
      
      if (supplyAfterNormalBurn < TARGET_SUPPLY) {
        await paulToken.executeBurn();
        const finalSupply = await paulToken.totalSupply();
        expect(finalSupply).to.be.at.most(TARGET_SUPPLY);
        expect(finalSupply).to.be.greaterThanOrEqual(TARGET_SUPPLY - 1n);
      }
    });
    
    it("应该触发 BurnStopped 事件", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      
      // 补充足够的储备金
      const neededReserve = ethers.parseUnits("1000000000", TOKEN_DECIMALS);
      await paulToken.replenishBurnReserve(neededReserve);
      await increaseTime(ONE_DAY);
      
      let currentSupply = await paulToken.totalSupply();
      let burnStopped = false;
      
      while (currentSupply > TARGET_SUPPLY && !burnStopped) {
        const tx = await paulToken.executeBurn();
        currentSupply = await paulToken.totalSupply();
        
        if (currentSupply <= TARGET_SUPPLY) {
          await expect(tx)
            .to.emit(paulToken, "BurnStopped")
            .withArgs(currentSupply, TARGET_SUPPLY);
          burnStopped = true;
          break;
        }
        
        await increaseTime(ONE_DAY);
      }
      
      expect(burnStopped).to.be.true;
    });
  });
  
  describe("销毁配置管理", function () {
    it("应该允许 owner 修改销毁比例", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const newPercent = 5;
      await paulToken.setBurnPercent(newPercent);
      expect(await paulToken.burnPercent()).to.equal(newPercent);
    });
    
    it("应该触发 BurnPercentUpdated 事件", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const newPercent = 5;
      await expect(paulToken.setBurnPercent(newPercent))
        .to.emit(paulToken, "BurnPercentUpdated")
        .withArgs(2, newPercent);
    });
    
    it("不能设置超出范围的销毁比例", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      await expect(paulToken.setBurnPercent(0)).to.be.revertedWith(
        "PaulToken: burn percent must be 1-10"
      );
      await expect(paulToken.setBurnPercent(11)).to.be.revertedWith(
        "PaulToken: burn percent must be 1-10"
      );
    });
    
    it("不能设置相同的销毁比例", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      await expect(paulToken.setBurnPercent(2)).to.be.revertedWith(
        "PaulToken: same burn percent"
      );
    });
    
    it("应该允许 owner 修改奖励池地址", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      const newRewardPool = account1.address;
      await paulToken.setRewardPool(newRewardPool);
      expect(await paulToken.rewardPool()).to.equal(newRewardPool);
    });
    
    it("不能设置零地址为奖励池", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const zeroAddress = "0x0000000000000000000000000000000000000000";
      await expect(paulToken.setRewardPool(zeroAddress)).to.be.revertedWith(
        "PaulToken: reward pool cannot be zero address"
      );
    });
    
    it("应该允许 owner 切换销毁功能开关", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      await paulToken.toggleBurn(false);
      expect(await paulToken.burnEnabled()).to.be.false;
      
      await paulToken.toggleBurn(true);
      expect(await paulToken.burnEnabled()).to.be.true;
    });
    
    it("应该允许 owner 补充销毁储备金", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const replenishAmount = ethers.parseUnits("500", TOKEN_DECIMALS);
      const reserveBefore = await paulToken.burnReserve();
      
      await paulToken.replenishBurnReserve(replenishAmount);
      
      const reserveAfter = await paulToken.burnReserve();
      expect(reserveAfter).to.equal(reserveBefore + replenishAmount);
    });
    
    it("补充销毁储备金时余额不足应回滚", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const tooMuch = ethers.parseUnits("1000000000000", TOKEN_DECIMALS);
      await expect(paulToken.replenishBurnReserve(tooMuch)).to.be.reverted;
    });
    
    it("应该触发 BurnReserveUpdated 事件", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const replenishAmount = ethers.parseUnits("500", TOKEN_DECIMALS);
      const reserveBefore = await paulToken.burnReserve();
      
      await expect(paulToken.replenishBurnReserve(replenishAmount))
        .to.emit(paulToken, "BurnReserveUpdated")
        .withArgs(reserveBefore + replenishAmount);
    });
  });
  
  describe("销毁恢复功能", function () {
    it("供应量等于或低于目标时不能通过 toggleBurn 启用", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      
      // 补充足够的储备金
      const neededReserve = ethers.parseUnits("1000000000", TOKEN_DECIMALS);
      await paulToken.replenishBurnReserve(neededReserve);
      await increaseTime(ONE_DAY);
      
      // 达到目标供应量
      let currentSupply = await paulToken.totalSupply();
      
      while (currentSupply > TARGET_SUPPLY) {
        await paulToken.executeBurn();
        await increaseTime(ONE_DAY);
        currentSupply = await paulToken.totalSupply();
      }
      
      // 尝试通过 toggleBurn 启用应该失败
      await expect(paulToken.toggleBurn(true)).to.be.revertedWith(
        "PaulToken: burn is permanently stopped (target reached)"
      );
    });
  });
  
  describe("查询功能测试", function () {
    it("应该正确返回下次可销毁时间", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const lastBurnTime = await paulToken.lastBurnTime();
      const nextBurnTime = await paulToken.nextBurnTime();
      expect(Number(nextBurnTime)).to.equal(Number(lastBurnTime) + ONE_DAY);
    });
    
    it("应该正确返回销毁状态信息", async function () {
      const { paulToken, rewardPool } = await deployPaulTokenFixture();
      const burnInfo = await paulToken.getBurnInfo();
      
      expect(burnInfo[0]).to.equal(2); // burnPercent
      expect(burnInfo[3]).to.equal(rewardPool.address); // rewardPool
      expect(burnInfo[4]).to.be.true; // burnEnabled
      expect(burnInfo[5]).to.be.false; // burnStopped
      expect(burnInfo[6]).to.equal(TARGET_SUPPLY); // targetSupply
    });
    
    it("应该正确返回距离目标的剩余销毁量", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const currentSupply = await paulToken.totalSupply();
      const remaining = await paulToken.getRemainingToTarget();
      
      if (currentSupply > TARGET_SUPPLY) {
        expect(remaining).to.equal(currentSupply - TARGET_SUPPLY);
      } else {
        expect(remaining).to.equal(0n);
      }
    });
    
    it("应该正确返回可销毁金额（考虑目标限制）", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const currentSupply = await paulToken.totalSupply();
      
      if (currentSupply > TARGET_SUPPLY) {
        const [burnToZero, burnToReward] = await paulToken.getBurnableAmounts();
        const burnAmount = burnToZero + burnToReward;
        const newSupply = currentSupply - burnAmount;
        expect(newSupply).to.be.greaterThanOrEqual(TARGET_SUPPLY - 1n);
      }
    });
  });
  
  describe("铸造功能测试", function () {
    it("应该允许 owner 铸造新代币", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      const mintAmount = ethers.parseUnits("1000000", TOKEN_DECIMALS);
      const totalSupplyBefore = await paulToken.totalSupply();
      
      await paulToken.mint(account1.address, mintAmount);
      
      const totalSupplyAfter = await paulToken.totalSupply();
      expect(totalSupplyAfter).to.equal(totalSupplyBefore + mintAmount);
      expect(await paulToken.balanceOf(account1.address)).to.equal(mintAmount);
    });
    
    it("应该触发 Mint 事件", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      const mintAmount = ethers.parseUnits("1000000", TOKEN_DECIMALS);
      await expect(paulToken.mint(account1.address, mintAmount))
        .to.emit(paulToken, "Mint")
        .withArgs(account1.address, mintAmount);
    });
    
    it("不能铸造超过最大供应量", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      const maxSupply = await paulToken.MAX_SUPPLY();
      const currentSupply = await paulToken.totalSupply();
      const tooMuch = maxSupply - currentSupply ;
      
      await expect(paulToken.mint(account1.address, tooMuch)).to.be.revertedWith(
        "PaulToken: mint amount exceeds max supply"
      );
    });
    
    it("不能铸造到零地址", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const mintAmount = ethers.parseUnits("1000", TOKEN_DECIMALS);
      const zeroAddress = "0x0000000000000000000000000000000000000000";
      await expect(paulToken.mint(zeroAddress, mintAmount)).to.be.revertedWith(
        "PaulToken: cannot mint to zero address"
      );
    });
    
    it("应该支持批量铸造", async function () {
      const { paulToken, account1, account2 } = await deployPaulTokenFixture();
      const recipients = [account1.address, account2.address];
      const amounts = [
        ethers.parseUnits("1000000", TOKEN_DECIMALS),
        ethers.parseUnits("2000000", TOKEN_DECIMALS),
      ];
      
      const totalSupplyBefore = await paulToken.totalSupply();
      const totalMint = amounts[0] + amounts[1];
      
      await paulToken.batchMint(recipients, amounts);
      
      const totalSupplyAfter = await paulToken.totalSupply();
      expect(totalSupplyAfter).to.equal(totalSupplyBefore + totalMint);
      expect(await paulToken.balanceOf(account1.address)).to.equal(amounts[0]);
      expect(await paulToken.balanceOf(account2.address)).to.equal(amounts[1]);
    });
    
    it("批量铸造时参数长度必须一致", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      const recipients = [account1.address];
      const amounts = [
        ethers.parseUnits("1000", TOKEN_DECIMALS),
        ethers.parseUnits("2000", TOKEN_DECIMALS),
      ];
      
      await expect(paulToken.batchMint(recipients, amounts)).to.be.revertedWith(
        "PaulToken: recipients and amounts length mismatch"
      );
    });
  });
  
  describe("转账功能测试", function () {
    it("应该成功转账", async function () {
      const { paulToken, account1, account2 } = await deployPaulTokenFixture();
      const transferAmount = ethers.parseUnits("1000000", TOKEN_DECIMALS);
      await paulToken.transfer(account1.address, transferAmount);
      
      const transferAmount2 = ethers.parseUnits("1000", TOKEN_DECIMALS);
      await paulToken.connect(account1).transfer(account2.address, transferAmount2);
      expect(await paulToken.balanceOf(account2.address)).to.equal(transferAmount2);
    });
    
    it("不能转账到零地址", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      const transferAmount = ethers.parseUnits("1000", TOKEN_DECIMALS);
      const zeroAddress = "0x0000000000000000000000000000000000000000";
      await expect(paulToken.transfer(zeroAddress, transferAmount)).to.be.revertedWith(
        "PaulToken: transfer to zero address"
      );
    });
    
    it("不能转账金额为0", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      await expect(paulToken.transfer(account1.address, 0)).to.be.revertedWith(
        "PaulToken: transfer value must be greater than zero"
      );
    });
    
    it("应该成功授权并转账", async function () {
      const { paulToken, owner, account1, account2 } = await deployPaulTokenFixture();
      const transferAmount = ethers.parseUnits("1000", TOKEN_DECIMALS);
      await paulToken.approve(account1.address, transferAmount);
      await paulToken
        .connect(account1)
        .transferFrom(owner.address, account2.address, transferAmount);
      expect(await paulToken.balanceOf(account2.address)).to.equal(transferAmount);
    });
    
    it("不能从零地址转账", async function () {
      const { paulToken, account2 } = await deployPaulTokenFixture();
      const transferAmount = ethers.parseUnits("1000", TOKEN_DECIMALS);
      const zeroAddress = "0x0000000000000000000000000000000000000000";
      await expect(
        paulToken.transferFrom(zeroAddress, account2.address, transferAmount)
      ).to.be.revertedWith("PaulToken: transfer from zero address");
    });
  });
  
  describe("权限控制测试", function () {
    it("非 owner 不能执行销毁", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      await expect(paulToken.connect(account1).executeBurn()).to.be.reverted;
    });
    
    it("非 owner 不能修改销毁比例", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      await expect(paulToken.connect(account1).setBurnPercent(5)).to.be.reverted;
    });
    
    it("非 owner 不能修改奖励池地址", async function () {
      const { paulToken, account1, account2 } = await deployPaulTokenFixture();
      await expect(paulToken.connect(account1).setRewardPool(account2.address)).to.be.reverted;
    });
    
    it("非 owner 不能切换销毁开关", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      await expect(paulToken.connect(account1).toggleBurn(false)).to.be.reverted;
    });
    
    it("非 owner 不能铸造", async function () {
      const { paulToken, account1, account2 } = await deployPaulTokenFixture();
      const mintAmount = ethers.parseUnits("1000", TOKEN_DECIMALS);
      await expect(paulToken.connect(account1).mint(account2.address, mintAmount)).to.be.reverted;
    });
    
    it("非 owner 不能补充销毁储备金", async function () {
      const { paulToken, account1 } = await deployPaulTokenFixture();
      const amount = ethers.parseUnits("100", TOKEN_DECIMALS);
      await expect(paulToken.connect(account1).replenishBurnReserve(amount)).to.be.reverted;
    });
  });
  
  describe("版本和辅助功能", function () {
    it("应该返回正确的版本号", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      expect(await paulToken.version()).to.equal("1.1.0");
    });
  });
  
  describe("完整通缩流程测试", function () {
    it("完整的通缩到2100万流程", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      
      // 补充足够的储备金以完成整个通缩过程
      const neededReserve = ethers.parseUnits("1000000000", TOKEN_DECIMALS);
      await paulToken.replenishBurnReserve(neededReserve);
      await increaseTime(ONE_DAY);
      
      let currentSupply = await paulToken.totalSupply();
      let burnCount = 0;
      
      console.log("\n=== 开始通缩流程 ===");
      console.log(`初始供应量: ${ethers.formatUnits(currentSupply, TOKEN_DECIMALS)}`);
      console.log(`目标供应量: ${ethers.formatUnits(TARGET_SUPPLY, TOKEN_DECIMALS)}`);
      console.log(
        `需要销毁: ${ethers.formatUnits(currentSupply - TARGET_SUPPLY, TOKEN_DECIMALS)}`
      );
      
      while (currentSupply > TARGET_SUPPLY && burnCount < 100) {
        const tx = await paulToken.executeBurn();
        const receipt = await tx.wait();
        
        burnCount++;
        currentSupply = await paulToken.totalSupply();
        
        console.log(
          `第 ${burnCount} 次销毁后剩余: ${ethers.formatUnits(currentSupply, TOKEN_DECIMALS)}`
        );
        
        if (currentSupply <= TARGET_SUPPLY) {
          console.log(`✅ 已达到目标供应量: ${ethers.formatUnits(TARGET_SUPPLY, TOKEN_DECIMALS)}`);
          
          const event = receipt?.logs.find(
            (log: any) => log.fragment?.name === "BurnStopped"
          );
          expect(event).to.exist;
          break;
        }
        
        await increaseTime(ONE_DAY);
      }
      
      expect(await paulToken.burnStopped()).to.be.true;
      expect(await paulToken.burnEnabled()).to.be.false;
      expect(await paulToken.totalSupply()).to.be.at.most(TARGET_SUPPLY);
      
      console.log(`\n=== 通缩完成 ===`);
      console.log(`总销毁次数: ${burnCount}`);
      console.log(
        `总销毁量: ${ethers.formatUnits(await paulToken.totalBurned(), TOKEN_DECIMALS)}`
      );
      console.log(
        `最终供应量: ${ethers.formatUnits(await paulToken.totalSupply(), TOKEN_DECIMALS)}`
      );
    });
  });
});