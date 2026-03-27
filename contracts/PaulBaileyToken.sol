// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PaulBaileyToken is ERC20, Ownable, ReentrancyGuard {
    
    // --- 状态变量和常量 ---
    uint256 public constant INITIAL_SUPPLY = 100_000_000_000 * 10**18;
    uint256 public constant DEFLATION_STOP_SUPPLY = 21_000_000 * 10**18;
    uint256 public constant BASE_SLIPPAGE_BPS = 1000;
    uint256 public constant DEFLATION_PERCENT_BPS = 200; //2%
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    address public treasuryWallet;
    address public projectWallet;
    address public pairAddress; //流动性地址
    
    // 通缩相关
    uint256 public lastDeflationTime=0;// 初始为0
    uint256 public burnShareBps = 5000;
    bool public deflationActive = true;

    // 定时器地址（可配置）
    address public timerAddress;
    
    // 价格与税收相关
    uint256 public lastRecordedPrice = 1 * 10**18; // 默认1:1
    uint256 public priceUpdateTimestamp;
    address public oracleAddress;
    
    // 授权铸造者（质押池）
    mapping(address => bool) public authorizedMinters;
    
    // --- 事件 ---
    event TokensSold(address indexed seller, uint256 tokenAmount, uint256 usd1Received, uint256 taxAmount);
    event DailyDeflationExecuted(uint256 amountRemovedFromPool, uint256 amountBurned, uint256 amountToProject);
    event TreasuryUpdated(address indexed newTreasury);
    event ProjectWalletUpdated(address indexed newProjectWallet);
    event PairAddressSet(address indexed pair);
    event OracleAddressUpdated(address indexed newOracle);
    event BurnShareUpdated(uint256 newBurnShareBps);
    event PriceUpdated(uint256 newPrice, uint256 timestamp);
    event AuthorizedMinterUpdated(address indexed minter, bool authorized);
    event RewardMinted(address indexed to, uint256 amount);
    
    // --- 修饰器 ---
    modifier onlyPair() {
        require(msg.sender == pairAddress, "Caller is not the pair");
        _;
    }
    
    modifier onlyAuthorizedMinter() {
        require(authorizedMinters[msg.sender] || msg.sender == owner(), "Not authorized to mint");
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
        
        
        // 100%合约用于通缩
        // _mint(address(this), INITIAL_SUPPLY); 
        // 给所有者1个代币，用于测试和初始操作
        _mint(initialOwner, 1 * 10**18);  // 1个PBL
        // 其余在合约中用于通缩
        _mint(address(this), INITIAL_SUPPLY - 1 * 10**18);

    }
    
    // --- 核心功能 1: 交易限制 ---
    function transfer(address, uint256) public pure override returns (bool) {
        revert("PaulBaileyToken: Transfers are disabled");
    }
    
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("PaulBaileyToken: Transfers are disabled");
    }
    
    function approve(address, uint256) public pure override returns (bool) {
        revert("PaulBaileyToken: Approvals are disabled");
    }
    
    function increaseAllowance(address, uint256) public pure returns (bool) {
        revert("PaulBaileyToken: Approvals are disabled");
    }
    
    function decreaseAllowance(address, uint256) public pure returns (bool) {
        revert("PaulBaileyToken: Approvals are disabled");
    }
    
    // --- 核心功能 2: 卖出与税收机制 ---
    /**
     * @notice 用户卖出保罗币，税收转入国库
     * @dev 实际DEX集成需调用外部Router
     */
    function sell(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "Cannot sell zero");
        require(balanceOf(msg.sender) >= tokenAmount, "Insufficient balance");
        require(pairAddress != address(0), "Trading pair not set");
        
        // 计算税率
        (uint256 taxBps, uint256 currentPrice) = _calculateEffectiveTax();
        uint256 taxAmount = (tokenAmount * taxBps) / 10000;
        uint256 tokensAfterTax = tokenAmount - taxAmount;
        
        // 从卖家账户扣除全部代币
        _burn(msg.sender, tokenAmount);
        
        // 模拟从交易对中向用户支付USD1
        uint256 estimatedUsd1Received = (tokensAfterTax * currentPrice) / 10**18;
        
        // 将税收部分转入国库
        if (taxAmount > 0) {
            // 通过特殊铸造实现税收转移
            _mint(treasuryWallet, taxAmount);
        }
        
        emit TokensSold(msg.sender, tokenAmount, estimatedUsd1Received, taxAmount);
    }
    
    /**
     * @notice 奖励铸造函数，供质押池调用
     * @dev 仅授权地址可调用
     */
    function mintReward(address to, uint256 amount) external onlyAuthorizedMinter {
        require(to != address(0), "Cannot mint to zero address");
        require(amount > 0, "Cannot mint zero amount");
        
        _mint(to, amount);
        emit RewardMinted(to, amount);
    }

    // 添加一个特殊转账函数，只允许通缩使用
    function _deflationTransfer(address from, address to, uint256 amount) internal {
       // 允许从合约转账给项目方或销毁地址
       bool isAllowed = (from == address(this) && 
                        (to == projectWallet || to == BURN_ADDRESS));
       
       require(isAllowed, "Deflation transfer not allowed");
       super._transfer(from, to, amount);
    }
    
    // --- 核心功能 3: 每日通缩销毁 ---
    function executeDailyDeflation() external onlyOwner deflationAllowed {
        // 时间检查
        if (lastDeflationTime > 0) {
            require(block.timestamp >= lastDeflationTime + 24 hours, "Can only deflate once per day");
        }
        
        require(totalSupply() > DEFLATION_STOP_SUPPLY, "Supply already at or below stop target");
        
        // 计算要销毁的总量
        uint256 amountToRemove = (totalSupply() * DEFLATION_PERCENT_BPS) / 10000;
        
        // 从合约自身销毁（合约需要有足够余额）
        require(balanceOf(address(this)) >= amountToRemove, "Contract has insufficient balance");
        _burn(address(this), amountToRemove);
        
        // 计算分配
        uint256 burnAmount = (amountToRemove * burnShareBps) / 10000;
        uint256 projectAmount = amountToRemove - burnAmount;
        
        // 给项目方转账
        if (projectAmount > 0) {
            _deflationTransfer(address(this), projectWallet, projectAmount);
        }
        
        // 销毁剩余部分
        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
        }
        
        // 更新时间戳
        lastDeflationTime = block.timestamp;
        
        // 检查停止条件
        if (totalSupply() <= DEFLATION_STOP_SUPPLY) {
            deflationActive = false;
        }
        
        emit DailyDeflationExecuted(amountToRemove, burnAmount, projectAmount);
    }

    // 允许合约接收代币
    function fundContract(uint256 amount) external onlyOwner {
        _transfer(owner(), address(this), amount);
    }
    
    // --- 辅助函数 ---
    function _calculateEffectiveTax() internal view returns (uint256, uint256) {
        uint256 baseTax = BASE_SLIPPAGE_BPS;
        uint256 dynamicTax = 0;
        uint256 currentPrice = _getCurrentPrice();
        
        if (lastRecordedPrice > 0 && currentPrice < lastRecordedPrice) {
            uint256 priceDrop = lastRecordedPrice - currentPrice;
            uint256 dropPercentage = (priceDrop * 10000) / lastRecordedPrice;
            if (dropPercentage > 1000) {// 跌幅 > 10%
                dynamicTax = dropPercentage;
            }
        }
        
        uint256 totalTax = baseTax + dynamicTax;
        if (totalTax > 10000) totalTax = 10000;
        
        return (totalTax, currentPrice);
    }
    
    function _getCurrentPrice() internal view returns (uint256) {
        // 预言机集成占位
        if (oracleAddress != address(0)) {
            // 实际调用预言机
            // return IOracle(oracleAddress).getLatestPrice();
        }
        return lastRecordedPrice;
    }
    
    // 特殊转账逻辑 - 移除 _transfer 重写，改为在 sell 函数中直接调用 _burn
    // 注意：由于 ERC20 的 _transfer 不是 virtual，我们不能直接重写它
    
    // --- 管理功能 ---
    function setAuthorizedMinter(address minter, bool authorized) external onlyOwner {
        authorizedMinters[minter] = authorized;
        emit AuthorizedMinterUpdated(minter, authorized);
    }
    
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
    
    /**
     * @notice 检查是否为授权铸造者
     */
    function isAuthorizedMinter(address account) external view returns (bool) {
        return authorizedMinters[account] || account == owner();
    }
}