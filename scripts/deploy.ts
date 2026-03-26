import { network } from "hardhat";

async function main() {
  
  const connection = await network.connect();
  // @ts-ignore - ethers 属性由 @nomicfoundation/hardhat-ethers 插件添加
  const { ethers } = connection;
  const [deployer] = await ethers.getSigners();

  console.log("Deploying PaulToken...");
  console.log("Deployer address:", deployer.address);
  console.log("Deployer balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // 获取合约工厂
  const PaulToken = await ethers.getContractFactory("PaulToken");
  
  // ✅ 方案1: 使用部署者地址作为奖励池
  const rewardPool = deployer.address;
  console.log("Reward pool address:", rewardPool);
  
  // 部署合约（传入奖励池地址参数）
  const token = await PaulToken.deploy(rewardPool);

  // 等待部署完成
  await token.waitForDeployment();
  const address = await token.getAddress();

  console.log("\n✅ PaulToken deployed to:", address);
  
  // 验证合约信息
  const name = await token.name();
  const symbol = await token.symbol();
  const decimals = await token.decimals();
  const totalSupply = await token.totalSupply();
  const owner = await token.owner();
  const rewardPoolAddr = await token.rewardPool();

  console.log("\n📊 Token Details:");
  console.log("  Name:", name);
  console.log("  Symbol:", symbol);
  console.log("  Decimals:", decimals);
  console.log("  Total Supply:", ethers.formatUnits(totalSupply, decimals), symbol);
  console.log("  Owner:", owner);
  console.log("  Reward Pool:", rewardPoolAddr);
  console.log("  Max Supply:", ethers.formatUnits(await token.MAX_SUPPLY(), decimals), symbol);
  console.log("  Version:", await token.version());
  console.log("  Burn Percent:", await token.burnPercent(), "%");
  console.log("  Burn Enabled:", await token.burnEnabled());
  
  // 显示部署者余额
  const deployerBalance = await token.balanceOf(deployer.address);
  console.log("\n💰 Deployer Balance:", ethers.formatUnits(deployerBalance, decimals), symbol);
  
  // 显示奖励池余额（初始应该为0）
  const rewardPoolBalance = await token.balanceOf(rewardPoolAddr);
  console.log("💰 Reward Pool Balance:", ethers.formatUnits(rewardPoolBalance, decimals), symbol);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });