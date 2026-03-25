// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin 合约导入
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PaulToken
 * @dev Paul Bailey Token 实现
 * 
 * 这是一个基础 ERC20 代币，具有以下特性：
 * - 名称: Paul Bailey Token
 * - 符号: PAUL
 * - 小数位数: 18
 * - 初始总供应量: 1000亿 (100,000,000,000)
 * - 所有者可铸造新代币
 * - 继承 OpenZeppelin 的安全特性
 * 
 * 注意：Solidity 0.8.x 版本已内置 SafeMath 功能
 */
contract PaulToken is ERC20, Ownable {
    
    /**
     * @dev 代币总供应量上限
     * 注意：这里没有硬性上限，但可以通过铸造限制来管理
     */
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 10**18; // 1万亿，预留扩展空间
    
    /**
     * @dev 自定义铸造事件
     * @param to 接收铸币的地址
     * @param amount 铸造的数量
     */
    event Mint(address indexed to, uint256 amount);
    
    /**
     * @dev 构造函数
     * 初始化代币并铸造初始供应量给合约部署者
     */
    constructor() 
        ERC20("Paul Bailey Token", "PAUL") 
        Ownable(msg.sender)  // 设置部署者为初始所有者
    {
        // 定义初始供应量
        uint256 initialSupply = 100_000_000_000 * 10**decimals(); // 1000亿代币
        
        // 铸造初始供应量给合约部署者
        _mint(msg.sender, initialSupply);
        
        // 记录初始铸造
        emit Mint(msg.sender, initialSupply);
    }
    
    /**
     * @dev 铸造新代币
     * 仅合约所有者可调用
     * 
     * 注意：铸造数量不应导致总供应量超过 MAX_SUPPLY
     * 
     * @param to 接收新铸代币的地址
     * @param amount 铸造的代币数量（以最小单位计）
     */
    function mint(address to, uint256 amount) external onlyOwner {
        // 检查接收地址是否有效
        require(to != address(0), "PaulToken: cannot mint to zero address");
        
        // 检查铸造数量是否有效
        require(amount > 0, "PaulToken: mint amount must be greater than zero");
        
        // 检查总供应量上限
        require(
            totalSupply() + amount <= MAX_SUPPLY,
            "PaulToken: mint amount exceeds max supply"
        );
        
        // 铸造代币
        _mint(to, amount);
        
        // 触发自定义铸造事件
        emit Mint(to, amount);
    }
    
    /**
     * @dev 批量铸造功能
     * 为多个地址一次性铸造代币
     * 仅合约所有者可调用
     * 
     * @param recipients 接收代币的地址数组
     * @param amounts 对应每个地址的铸造数量数组
     */
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner {
        // 检查数组长度是否匹配
        require(
            recipients.length == amounts.length,
            "PaulToken: recipients and amounts length mismatch"
        );
        
        uint256 totalMintAmount = 0;
        
        // 计算总铸造量并检查
        for (uint256 i = 0; i < recipients.length; i++) {
            require(
                recipients[i] != address(0),
                "PaulToken: cannot mint to zero address"
            );
            require(
                amounts[i] > 0,
                "PaulToken: mint amount must be greater than zero"
            );
            
            totalMintAmount += amounts[i];
        }
        
        // 检查总供应量上限
        require(
            totalSupply() + totalMintAmount <= MAX_SUPPLY,
            "PaulToken: total mint amount exceeds max supply"
        );
        
        // 批量铸造
        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], amounts[i]);
            emit Mint(recipients[i], amounts[i]);
        }
    }
    
    /**
     * @dev 获取当前合约版本
     * @return 版本字符串
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
    
    /**
     * @dev 获取代币精度
     * 重写父类方法，提供更清晰的接口
     * @return 小数位数
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }
    
    /**
     * @dev 重写 transfer 方法，添加额外检查
     * 在 Solidity 0.8+ 中，溢出检查是内置的
     * 
     * @param to 接收地址
     * @param value 转账数量
     * @return 是否成功
     */
    function transfer(address to, uint256 value) public override returns (bool) {
        // 基础检查
        require(to != address(0), "PaulToken: transfer to zero address");
        require(value > 0, "PaulToken: transfer value must be greater than zero");
        
        // 调用父类转账
        return super.transfer(to, value);
    }
    
    /**
     * @dev 重写 transferFrom 方法，添加额外检查
     * 
     * @param from 发送地址
     * @param to 接收地址
     * @param value 转账数量
     * @return 是否成功
     */
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        // 基础检查
        require(from != address(0), "PaulToken: transfer from zero address");
        require(to != address(0), "PaulToken: transfer to zero address");
        require(value > 0, "PaulToken: transfer value must be greater than zero");
        
        // 调用父类转账
        return super.transferFrom(from, to, value);
    }
}