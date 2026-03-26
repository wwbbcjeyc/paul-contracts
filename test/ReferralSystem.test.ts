// 测试用例示例
import { expect } from "chai";
import { network } from "hardhat";

describe("ReferralSystem", function () {
  let ReferralSystem: any;
  let referralSystem: any;
  let owner: any;
  let user1: any;
  let user2: any;
  let user3: any;
  let user4: any;
  let ethers: any;

  beforeEach(async function () {
    const connection = await network.connect();
    ethers = connection.ethers;
    [owner, user1, user2, user3, user4] = await ethers.getSigners();
    
    const ReferralSystemFactory = await ethers.getContractFactory("ReferralSystem");
    referralSystem = await ReferralSystemFactory.deploy();
    await referralSystem.waitForDeployment();
  });

  describe("关系绑定", function () {
    it("应该成功绑定推荐关系", async function () {
      // 用户1绑定owner为推荐人
      await referralSystem.connect(user1).bindReferrer(owner.address);
      
      const info = await referralSystem.referrerInfo(user1.address);
      expect(info.referrer).to.equal(owner.address);
      expect(info.isActive).to.be.false;
    });

    it("应该防止重复绑定", async function () {
      await referralSystem.connect(user1).bindReferrer(owner.address);
      
      await expect(
        referralSystem.connect(user1).bindReferrer(user2.address)
      ).to.be.revertedWith("User already registered");
    });

    it("应该防止自我推荐", async function () {
      await expect(
        referralSystem.connect(user1).bindReferrer(user1.address)
      ).to.be.revertedWith("Cannot refer yourself");
    });

    it("应该防止循环推荐", async function () {
      // A -> B -> C -> A 形成循环
      await referralSystem.connect(user1).bindReferrer(owner.address);
      await referralSystem.connect(user2).bindReferrer(user1.address);
      await referralSystem.connect(user3).bindReferrer(user2.address);
      
      await expect(
        referralSystem.connect(user1).bindReferrer(user3.address)
      ).to.be.revertedWith("Circular reference detected");
    });
  });

  describe("紧缩机制", function () {
    beforeEach(async function () {
      // 构建关系链: owner -> user1 -> user2 -> user3 -> user4
      await referralSystem.connect(user1).bindReferrer(owner.address);
      await referralSystem.connect(user2).bindReferrer(user1.address);
      await referralSystem.connect(user3).bindReferrer(user2.address);
      await referralSystem.connect(user4).bindReferrer(user3.address);
    });

    it("应该正确计算紧缩后的推荐链", async function () {
      // 激活owner和user2，user1保持非活跃
      await referralSystem.connect(owner).activateUser(owner.address);
      await referralSystem.connect(owner).activateUser(user2.address);
      
      // 获取user4的推荐链（最大3代）
      const chain = await referralSystem.getReferralChain(user4.address, 3);
      
      // 应该只有user2和owner（跳过非活跃的user1和user3）
      expect(chain.length).to.equal(2);
      expect(chain[0]).to.equal(user2.address); // 第1代
      expect(chain[1]).to.equal(owner.address); // 第2代
    });

    it("应该正确计算代数奖励", async function () {
      // 激活所有用户
      await referralSystem.connect(owner).activateUser(owner.address);
      await referralSystem.connect(owner).activateUser(user1.address);
      await referralSystem.connect(owner).activateUser(user2.address);
      await referralSystem.connect(owner).activateUser(user3.address);
      await referralSystem.connect(owner).activateUser(user4.address);
      
      const [receivers, amounts, generations] = await referralSystem.calculateReferralRewards(
        ethers.parseEther("100"),
        user4.address
      );
      
      expect(receivers.length).to.equal(3);
      expect(generations[0]).to.equal(1); // user3
      expect(generations[1]).to.equal(2); // user2
      expect(generations[2]).to.equal(3); // user1
      
      // 验证奖励比例
      expect(amounts[0]).to.equal(ethers.parseEther("10"));  // 10%
      expect(amounts[1]).to.equal(ethers.parseEther("5"));   // 5%
      expect(amounts[2]).to.equal(ethers.parseEther("2"));   // 2%
    });
  });

  describe("活跃推荐计数", function () {
    it("应该正确更新活跃推荐数量", async function () {
      // owner -> user1 -> user2
      await referralSystem.connect(user1).bindReferrer(owner.address);
      await referralSystem.connect(user2).bindReferrer(user1.address);
      
      // 激活owner
      await referralSystem.connect(owner).activateUser(owner.address);
      expect(await referralSystem.activeReferralCount(owner.address)).to.equal(0);
      
      // 激活user1
      await referralSystem.connect(owner).activateUser(user1.address);
      expect(await referralSystem.activeReferralCount(owner.address)).to.equal(1);
      
      // 激活user2
      await referralSystem.connect(owner).activateUser(user2.address);
      expect(await referralSystem.activeReferralCount(user1.address)).to.equal(1);
      expect(await referralSystem.activeReferralCount(owner.address)).to.equal(1); // 保持不变
    });
  });

  describe("奖励发放", function () {
    it("应该正确分配奖励", async function () {
      // 部署测试代币
      const TestToken = await ethers.getContractFactory("ERC20Mock");
      const testToken = await TestToken.deploy("Test", "TEST", owner.address, ethers.parseEther("1000"));
      
      // 设置关系链
      await referralSystem.connect(user1).bindReferrer(owner.address);
      await referralSystem.connect(user2).bindReferrer(user1.address);
      
      // 激活所有用户
      await referralSystem.connect(owner).activateUser(owner.address);
      await referralSystem.connect(owner).activateUser(user1.address);
      await referralSystem.connect(owner).activateUser(user2.address);
      
      // 批准合约使用代币
      await testToken.connect(owner).approve(
        await referralSystem.getAddress(),
        ethers.parseEther("100")
      );
      
      // 分发奖励
      await referralSystem.connect(owner).distributeRewards(
        await testToken.getAddress(),
        user2.address,
        ethers.parseEther("100")
      );
      
      // 验证余额
      expect(await testToken.balanceOf(user1.address)).to.equal(ethers.parseEther("10")); // 10%
      expect(await testToken.balanceOf(owner.address)).to.equal(
        ethers.parseEther("900") + ethers.parseEther("5") // 剩余 + 5%奖励
      );
    });
  });
});