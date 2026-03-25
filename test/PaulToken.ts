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
  
  // 部署夹具
  async function deployPaulTokenFixture() {
    const [owner, account1, account2] = signers;
    
    const paulToken = await ethers.deployContract("PaulToken");
    
    return { paulToken, owner, account1, account2 };
  }
  
  // 代币常量
  const TOKEN_NAME = "Paul Bailey Token";
  const TOKEN_SYMBOL = "PAUL";
  const TOKEN_DECIMALS = 18;
  const INITIAL_SUPPLY = 100000000000n * 10n ** 18n;
  const MAX_SUPPLY = 1000000000000n * 10n ** 18n;
  
  describe("部署和初始化", function () {
    it("应该正确部署合约", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      
      expect(await paulToken.getAddress()).to.be.properAddress;
    });
    
    it("应该设置正确的代币信息", async function () {
      const { paulToken } = await deployPaulTokenFixture();
      
      expect(await paulToken.name()).to.equal(TOKEN_NAME);
      expect(await paulToken.symbol()).to.equal(TOKEN_SYMBOL);
      expect(await paulToken.decimals()).to.equal(TOKEN_DECIMALS);
    });
    
    it("应该铸造初始供应量给部署者", async function () {
      const { paulToken, owner } = await deployPaulTokenFixture();
      
      const ownerBalance = await paulToken.balanceOf(owner.address);
      expect(ownerBalance).to.equal(INITIAL_SUPPLY);
      
      const totalSupply = await paulToken.totalSupply();
      expect(totalSupply).to.equal(INITIAL_SUPPLY);
    });
    
    it("应该设置正确的所有者", async function () {
          const { paulToken, owner } = await deployPaulTokenFixture();
          
          expect(await paulToken.owner()).to.equal(owner.address);
    });

    it("应该返回正确的版本号", async function () {
          const { paulToken } = await deployPaulTokenFixture();
          
          expect(await paulToken.version()).to.equal("1.0.0");
    });
  });

  describe("转账功能", function () {
    it("应该允许代币转账", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      const transferAmount = 1000n * 10n ** 18n;
      await paulToken.connect(owner).transfer(account1.address, transferAmount);
      
      const account1Balance = await paulToken.balanceOf(account1.address);
      expect(account1Balance).to.equal(transferAmount);
      
      const ownerNewBalance = await paulToken.balanceOf(owner.address);
      expect(ownerNewBalance).to.equal(INITIAL_SUPPLY - transferAmount);
    });
    
    it("应该触发Transfer事件", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      const transferAmount = 1000n * 10n ** 18n;
      await expect(paulToken.connect(owner).transfer(account1.address, transferAmount))
        .to.emit(paulToken, "Transfer")
        .withArgs(owner.address, account1.address, transferAmount);
    });
    
    it("应该拒绝向零地址转账", async function () {
      const { paulToken, owner } = await deployPaulTokenFixture();
      
      const transferAmount = 1000n * 10n ** 18n;
      await expect(
        paulToken.connect(owner).transfer(ethers.ZeroAddress, transferAmount)
      ).to.be.revertedWith("PaulToken: transfer to zero address");
    });
    
    it("应该拒绝转账金额为零", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      await expect(
        paulToken.connect(owner).transfer(account1.address, 0n)
      ).to.be.revertedWith("PaulToken: transfer value must be greater than zero");
    });
    
    it("应该拒绝余额不足的转账", async function () {
      const { paulToken, account1, account2 } = await deployPaulTokenFixture();
      
      const transferAmount = 1n * 10n ** 18n;
      await expect(
        paulToken.connect(account1).transfer(account2.address, transferAmount)
      ).to.be.revertedWithCustomError(paulToken, "ERC20InsufficientBalance");
    });
    
    describe("授权转账", function () {
      it("应该允许授权转账", async function () {
        const { paulToken, owner, account1, account2 } = await deployPaulTokenFixture();
        
        const allowanceAmount = 1000n * 10n ** 18n;
        const transferAmount = 500n * 10n ** 18n;
        
        // 授权
        await paulToken.connect(owner).approve(account1.address, allowanceAmount);
        
        // 检查授权金额
        const allowance = await paulToken.allowance(owner.address, account1.address);
        expect(allowance).to.equal(allowanceAmount);
        
        // 执行转账
        await paulToken.connect(account1).transferFrom(
          owner.address,
          account2.address,
          transferAmount
        );
        
        // 检查余额
        const account2Balance = await paulToken.balanceOf(account2.address);
        expect(account2Balance).to.equal(transferAmount);
        
        // 检查剩余授权
        const remainingAllowance = await paulToken.allowance(owner.address, account1.address);
        expect(remainingAllowance).to.equal(allowanceAmount - transferAmount);
      });
    });
  });
  
  describe("铸造功能", function () {
    it("应该允许所有者铸造新代币", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      const mintAmount = 1000n * 10n ** 18n;
      const initialTotalSupply = await paulToken.totalSupply();
      
      await paulToken.connect(owner).mint(account1.address, mintAmount);
      
      const account1Balance = await paulToken.balanceOf(account1.address);
      expect(account1Balance).to.equal(mintAmount);
      
      const newTotalSupply = await paulToken.totalSupply();
      expect(newTotalSupply).to.equal(initialTotalSupply + mintAmount);
    });
    
    it("应该触发Mint事件", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      const mintAmount = 1000n * 10n ** 18n;
      await expect(paulToken.connect(owner).mint(account1.address, mintAmount))
        .to.emit(paulToken, "Mint")
        .withArgs(account1.address, mintAmount);
    });
    
    it("应该拒绝非所有者铸造代币", async function () {
      const { paulToken, account1, account2 } = await deployPaulTokenFixture();
      
      const mintAmount = 1000n * 10n ** 18n;
      await expect(
        paulToken.connect(account1).mint(account2.address, mintAmount)
      ).to.be.revertedWithCustomError(paulToken, "OwnableUnauthorizedAccount");
    });
    
    it("应该拒绝向零地址铸造", async function () {
      const { paulToken, owner } = await deployPaulTokenFixture();
      
      const mintAmount = 1000n * 10n ** 18n;
      await expect(
        paulToken.connect(owner).mint(ethers.ZeroAddress, mintAmount)
      ).to.be.revertedWith("PaulToken: cannot mint to zero address");
    });
    
    it("应该拒绝铸造零数量代币", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      await expect(
        paulToken.connect(owner).mint(account1.address, 0n)
      ).to.be.revertedWith("PaulToken: mint amount must be greater than zero");
    });
    
    it("应该拒绝超过最大供应量的铸造", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      // 尝试铸造超过最大供应量的代币
      const exceedAmount = MAX_SUPPLY - await paulToken.totalSupply() + 1n;
      
      await expect(
        paulToken.connect(owner).mint(account1.address, exceedAmount)
      ).to.be.revertedWith("PaulToken: mint amount exceeds max supply");
    });
    
    describe("批量铸造", function () {
      it("应该允许批量铸造", async function () {
        const { paulToken, owner, account1, account2 } = await deployPaulTokenFixture();
        
        const recipients = [account1.address, account2.address];
        const amounts = [
          1000n * 10n ** 18n,
          2000n * 10n ** 18n
        ];
        
        const initialTotalSupply = await paulToken.totalSupply();
        
        await paulToken.connect(owner).batchMint(recipients, amounts);
        
        // 检查余额
        const balance1 = await paulToken.balanceOf(account1.address);
        const balance2 = await paulToken.balanceOf(account2.address);
        
        expect(balance1).to.equal(amounts[0]);
        expect(balance2).to.equal(amounts[1]);
        
        // 检查总供应量
        const newTotalSupply = await paulToken.totalSupply();
        const expectedTotalSupply = initialTotalSupply + amounts[0] + amounts[1];
        expect(newTotalSupply).to.equal(expectedTotalSupply);
      });
      
      it("应该拒绝长度不匹配的批量铸造", async function () {
        const { paulToken, owner, account1, account2 } = await deployPaulTokenFixture();
        
        const recipients = [account1.address, account2.address];
        const amounts = [1000n * 10n ** 18n]; // 长度不匹配
        
        await expect(
          paulToken.connect(owner).batchMint(recipients, amounts)
        ).to.be.revertedWith("PaulToken: recipients and amounts length mismatch");
      });
    });
  });
  
  describe("所有权管理", function () {
    it("应该允许所有者转移所有权", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      await paulToken.connect(owner).transferOwnership(account1.address);
      
      expect(await paulToken.owner()).to.equal(account1.address);
    });
    
    it("应该拒绝非所有者转移所有权", async function () {
      const { paulToken, account1, account2 } = await deployPaulTokenFixture();
      
      await expect(
        paulToken.connect(account1).transferOwnership(account2.address)
      ).to.be.revertedWithCustomError(paulToken, "OwnableUnauthorizedAccount");
    });
  });
  
  describe("边界情况", function () {
    it("应该正确处理最大供应量", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      const currentSupply = await paulToken.totalSupply();
      const remainingMint = MAX_SUPPLY - currentSupply;
      
      // 铸造剩余的额度
      await paulToken.connect(owner).mint(account1.address, remainingMint);
      
      const newTotalSupply = await paulToken.totalSupply();
      expect(newTotalSupply).to.equal(MAX_SUPPLY);
      
      // 尝试再铸造 1 wei
      await expect(
        paulToken.connect(owner).mint(account1.address, 1n)
      ).to.be.revertedWith("PaulToken: mint amount exceeds max supply");
    });
    
    it("应该正确处理大额转账", async function () {
      const { paulToken, owner, account1 } = await deployPaulTokenFixture();
      
      const largeAmount = INITIAL_SUPPLY; // 转账全部余额
      await paulToken.connect(owner).transfer(account1.address, largeAmount);
      
      const account1Balance = await paulToken.balanceOf(account1.address);
      expect(account1Balance).to.equal(largeAmount);
    });
  });
});