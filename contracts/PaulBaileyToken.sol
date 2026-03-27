// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PaulBaileyToken is ERC20, Ownable, ReentrancyGuard {

    
    // --- 状态变量和常量 ---
    uint256 public constant INITIAL_SUPPLY = 100_000_000_000 * 10**18; // 1000亿，18位小数
    uint256 public constant DEFLATION_STOP_SUPPLY = 21_000_000 * 10**18; // 2100万停止通缩
    uint256 public constant BASE_SLIPPAGE_BPS = 1000; // 基础滑点税 10% = 1000/10000
    uint256 public constant DEFLATION_PERCENT_BPS = 200; // 每日通缩 2% = 200/10000
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address public treasuryWallet; // 国库地址 (EOA)
    address public projectWallet; // 项目方接收通缩代币的钱包
    address public pairAddress; // 保罗币/USD1 交易对地址，需在初始化后设置

    // 通缩相关
    uint256 public lastDeflationTime; // 上次通缩执行时间戳
    uint256 public burnShareBps = 5000; // 销毁份额，默认50% (5000/10000)，可配置
    bool public deflationActive = true; // 通缩是否激活

    // 价格与税收相关
    uint256 public lastRecordedPrice; // 上次记录的价格 (USD1 per token, 缩放精度)
    uint256 public priceUpdateTimestamp;
    address public oracleAddress; // 预言机地址（预留）

    // --- 事件 ---
    event TokensSold(address indexed seller, uint256 tokenAmount, uint256 usd1Received, uint256 taxAmount);
    event DailyDeflationExecuted(uint256 amountRemovedFromPool, uint256 amountBurned, uint256 amountToProject);
    event TreasuryUpdated(address indexed newTreasury);
    event ProjectWalletUpdated(address indexed newProjectWallet);
    event PairAddressSet(address indexed pair);
    event OracleAddressUpdated(address indexed newOracle);
    event BurnShareUpdated(uint256 newBurnShareBps);
    event PriceUpdated(uint256 newPrice, uint256 timestamp);

    // --- 修饰器 ---
    modifier onlyPair() {
        require(msg.sender == pairAddress, "Caller is not the pair");
        _;
    }

    modifier deflationAllowed() {
        require(deflationActive, "Deflation has been permanently stopped");
        _;
    }

    // --- 构造函数和初始化 ---
    constructor(
        address initialOwner,
        address _treasuryWallet,
        address _projectWallet
    ) ERC20("PaulBailey", "PBL") Ownable(initialOwner) {
        require(_treasuryWallet != address(0) && _projectWallet != address(0), "Zero address not allowed");

        treasuryWallet = _treasuryWallet;
        projectWallet = _projectWallet;
        lastDeflationTime = block.timestamp;

        // 一次性铸造全部初始供应量给部署者（后续将由部署脚本注入流动性）
        _mint(initialOwner, INITIAL_SUPPLY);
    }

    // --- 核心功能 1: 交易限制 (不可转账) ---
    /**
     * @dev 重写 transfer 函数，使其永远回滚，实现"不可转账"。
     */
    function transfer(address /* to */, uint256 /* amount */) public pure override returns (bool) {
        revert("PaulBaileyToken: Transfers are disabled");
    }

    /**
     * @dev 重写 transferFrom 函数，使其永远回滚。
     */
    function transferFrom(address /* from */, address /* to */, uint256 /* amount */) public pure override returns (bool) {
        revert("PaulBaileyToken: Transfers are disabled");
    }

    /**
     * @dev 重写 approve 函数，彻底禁用授权，确保"不可转账"的完整性。
     */
    function approve(address /* spender */, uint256 /* amount */) public pure override returns (bool) {
        revert("PaulBaileyToken: Approvals are disabled");
    }

    // 可选：同样禁用 increaseAllowance 和 decreaseAllowance
    function increaseAllowance(address /* spender */, uint256 /* addedValue */) public pure returns (bool) {
        revert("PaulBaileyToken: Approvals are disabled");
    }
    function decreaseAllowance(address /* spender */, uint256 /* subtractedValue */) public pure returns (bool) {
        revert("PaulBaileyToken: Approvals are disabled");
    }

    // --- 核心功能 2: 卖出与税收机制 (只能卖出) ---
    /**
     * @notice 用户调用此函数卖出保罗币，换取USD1。税收（基础+动态）转入国库。
     * @param tokenAmount 要卖出的保罗币数量
     */
    function sell(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "Cannot sell zero");
        require(balanceOf(msg.sender) >= tokenAmount, "Insufficient balance");
        require(pairAddress != address(0), "Trading pair not set");

        // 1. 计算税
        (uint256 taxBasisPoints, uint256 currentPrice) = _calculateEffectiveTax();
        // 删除 .mul 使用标准乘法
        uint256 taxAmount = (tokenAmount * taxBasisPoints) / 10000;
        uint256 tokensAfterTax = tokenAmount - taxAmount;

        // 2. 从卖家账户扣除全部代币
        _burn(msg.sender, tokenAmount); // 通过销毁实现扣除

        // 3. 模拟从交易对中向用户支付USD1 (需与Pair合约实际交互)
        // 此处为简化示意。实际实现需调用pair合约的swap功能。
        // 假设 pair.swap(tokensAfterTax, msg.sender) 的逻辑，此处省略具体DEX调用。
        // 为了可编译，我们注释掉实际调用，仅模拟事件。
        uint256 estimatedUsd1Received = (tokensAfterTax * currentPrice) / 10**18; // 简化估算

        // 4. 将税收部分转入国库
        if (taxAmount > 0) {
            _mint(treasuryWallet, taxAmount); // 将税收代币铸造给国库
        }

        emit TokensSold(msg.sender, tokenAmount, estimatedUsd1Received, taxAmount);
    }

    /**
     * @dev 内部函数，计算有效税率（基础税率+动态税率）。
     * @return effectiveTaxBps 有效税率，单位为基点 (basis points)。
     * @return currentPrice 当前价格（供后续计算使用）。
     * 注意：动态税率依赖于可信的"上次价格"。此版本使用管理员更新的价格。
     * 生产环境必须集成链上预言机！
     */
    function _calculateEffectiveTax() internal view returns (uint256 effectiveTaxBps, uint256 currentPrice) {
        uint256 baseTax = BASE_SLIPPAGE_BPS;
        uint256 dynamicTax = 0;

        // 获取当前价格（这里应从预言机获取，此处为简化使用存储值）
        currentPrice = _getCurrentPrice(); // 假设此函数返回带精度的价格

        if (lastRecordedPrice > 0 && currentPrice < lastRecordedPrice) {
            uint256 priceDrop = lastRecordedPrice - currentPrice;
            // 使用标准数学运算
            uint256 dropPercentage = (priceDrop * 10000) / lastRecordedPrice; // 跌幅，单位基点
            if (dropPercentage > 1000) { // 跌幅 > 10%
                dynamicTax = dropPercentage; // 动态税率 = 实时跌幅
            }
        }
        // 总税率 = 基础税率 + 动态税率
        effectiveTaxBps = baseTax + dynamicTax;
        // 确保税率不超过100%
        if (effectiveTaxBps > 10000) {
            effectiveTaxBps = 10000;
        }
    }

    // 简化版价格获取函数（需替换为预言机）
    function _getCurrentPrice() internal view returns (uint256) {
        // 此处应调用预言机合约。为编译通过，返回一个存值。
        // 生产环境示例: return IOracle(oracleAddress).getLatestPrice();
        return lastRecordedPrice > 0 ? lastRecordedPrice : 1 * 10**18; // 默认1 USD1
    }

    // --- 核心功能 3: 每日通缩销毁 ---
    /**
     * @notice 管理员调用此函数，执行每日通缩。每日只能调用一次。
     */
    function executeDailyDeflation() external onlyOwner deflationAllowed {
        require(block.timestamp >= lastDeflationTime + 24 hours, "Can only deflate once per day");
        require(totalSupply() > DEFLATION_STOP_SUPPLY, "Supply already at or below stop target");

        // 1. 计算应从流动性池中移除的代币数量 (当前总供应量的2%)
        uint256 amountToRemove = (totalSupply() * DEFLATION_PERCENT_BPS) / 10000;

        // 2. 从总供应量中销毁这部分代币（模拟从流动性池移除）
        // 注意：实际操作中，可能需要从Pair合约地址中直接转账/销毁。
        // 这里假设Pair合约持有流动性代币，我们需从其账户中销毁。
        // 为简化，我们直接全局销毁，代表从流通中移除。
        _burn(pairAddress, amountToRemove); // 关键：从交易对地址销毁代币

        // 3. 分配移除的代币
        uint256 burnAmount = (amountToRemove * burnShareBps) / 10000;
        uint256 projectAmount = amountToRemove - burnAmount;

        // 实际转账（销毁和给项目方）
        if (burnAmount > 0) {
            _transferToBurnAddress(burnAmount); // 自定义销毁函数
        }
        if (projectAmount > 0) {
            _mint(projectWallet, projectAmount);
        }

        // 4. 更新状态
        lastDeflationTime = block.timestamp;

        // 5. 检查停止条件
        if (totalSupply() <= DEFLATION_STOP_SUPPLY) {
            deflationActive = false;
        }

        emit DailyDeflationExecuted(amountToRemove, burnAmount, projectAmount);
    }

    // 辅助函数：将代币转入销毁地址（这需要销毁地址拥有余额）
    function _transferToBurnAddress(uint256 amount) internal {
        // 由于我们禁用了transfer，这里需要特殊处理。
        // 直接铸造给销毁地址
        _mint(BURN_ADDRESS, amount);
    }

    // --- 管理功能（仅所有者）---
    function setPairAddress(address _pairAddress) external onlyOwner {
        require(_pairAddress != address(0), "Invalid pair address");
        pairAddress = _pairAddress;
        emit PairAddressSet(_pairAddress);
    }

    function setTreasuryWallet(address _treasuryWallet) external onlyOwner {
        require(_treasuryWallet != address(0), "Invalid treasury address");
        treasuryWallet = _treasuryWallet;
        emit TreasuryUpdated(_treasuryWallet);
    }

    function setProjectWallet(address _projectWallet) external onlyOwner {
        require(_projectWallet != address(0), "Invalid project wallet");
        projectWallet = _projectWallet;
        emit ProjectWalletUpdated(_projectWallet);
    }

    function setOracleAddress(address _oracleAddress) external onlyOwner {
        oracleAddress = _oracleAddress;
        emit OracleAddressUpdated(_oracleAddress);
    }

    function setBurnShare(uint256 _burnShareBps) external onlyOwner {
        require(_burnShareBps <= 10000, "Share must be <= 100%");
        burnShareBps = _burnShareBps;
        emit BurnShareUpdated(_burnShareBps);
    }

    /**
     * @notice 更新价格（临时方案，生产环境必须用预言机替代）
     */
    function updatePriceManually(uint256 _newPrice) external onlyOwner {
        require(_newPrice > 0, "Price must be positive");
        lastRecordedPrice = _newPrice;
        priceUpdateTimestamp = block.timestamp;
        emit PriceUpdated(_newPrice, block.timestamp);
    }

    // --- 视图函数 ---
    function getEffectiveTaxRate() external view returns (uint256) {
        (uint256 taxBps, ) = _calculateEffectiveTax();
        return taxBps;
    }

    function timeUntilNextDeflation() external view returns (uint256) {
        if (!deflationActive) return 0;
        if (block.timestamp < lastDeflationTime + 24 hours) {
            return (lastDeflationTime + 24 hours) - block.timestamp;
        }
        return 0;
    }
}