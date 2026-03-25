// ignition/modules/PaulToken.ts
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("PaulTokenModule", (m) => {
  // 部署 PaulToken 合约
  // 注意：构造函数不需要参数，因为初始供应量已经在合约内定义
  const paulToken = m.contract("PaulToken");
  
  return { paulToken };
});