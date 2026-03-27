import { defineConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-network-helpers";
import hardhatIgnitionPlugin from "@nomicfoundation/hardhat-ignition";
import "@nomicfoundation/hardhat-ignition-ethers";
import "@nomicfoundation/hardhat-verify";
import "@nomicfoundation/hardhat-typechain";
import "@nomicfoundation/hardhat-ethers-chai-matchers";
import hardhatToolboxMochaEthersPlugin from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import * as dotenv from "dotenv";

// 加载环境变量
dotenv.config();


export default defineConfig({
  plugins: [hardhatToolboxMochaEthersPlugin,hardhatIgnitionPlugin],
  // Mocha 配置通过插件自动处理，无需在此处配置
  // 如需自定义超时时间，可以在测试文件中使用 mocha.timeout() 或在命令行使用 --timeout 参数
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    // 本地 Hardhat 网络（EDR 模拟）
    hardhat: {
      type: "edr-simulated",
      chainId: 31337,
    },
    localhost: {
      type: "http",
      chainType: "l1",
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
    sepolia: {
      type: "http",
      chainType: "l1", 
      url:process.env.SEPOLIA_RPC_URL || "", 
      accounts: process.env.SEPOLIA_PRIVATE_KEY ? [process.env.SEPOLIA_PRIVATE_KEY] : [],
      chainId: 11155111,
      timeout: 120000, // 120 秒超时
      httpHeaders: {},
    },
  },
});