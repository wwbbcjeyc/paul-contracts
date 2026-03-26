import { network } from "hardhat";

async function main() {
  const connection = await network.connect();
  const { ethers } = connection;
  const [deployer] = await ethers.getSigners();

  console.log("Deploying PaulToken...");
  console.log("Deployer address:", deployer.address);
  console.log("Deployer balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // 获取合约工厂（你的合约文件会被自动找到）
  const PaulToken = await ethers.getContractFactory("PaulToken");
  
  // 部署合约（构造函数无参数）
  const token = await PaulToken.deploy();

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

  console.log("\n📊 Token Details:");
  console.log("  Name:", name);
  console.log("  Symbol:", symbol);
  console.log("  Decimals:", decimals);
  console.log("  Total Supply:", ethers.formatUnits(totalSupply, decimals), symbol);
  console.log("  Owner:", owner);
  console.log("  Max Supply:", ethers.formatUnits(await token.MAX_SUPPLY(), decimals), symbol);
  console.log("  Version:", await token.version());
  
  // 显示部署者余额
  const deployerBalance = await token.balanceOf(deployer.address);
  console.log("\n💰 Deployer Balance:", ethers.formatUnits(deployerBalance, decimals), symbol);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });