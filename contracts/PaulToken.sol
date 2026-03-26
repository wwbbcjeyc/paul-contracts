// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin 合约导入
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PaulToken
 * @dev PaulTokenul Bailey Token 实现 - 带有通缩销毁机制的 ERC20 代币
 * 
 * 这是一个具有通缩经济模型的 ERC20 代币，具有以下特性：
 * - 名称: PaulTokenul Bailey Token
 * - 符号: PaulTokenUL
 * - 小数位数: 18
 * - 初始总供应量: 1000亿 (100,000,000,000)
 * - 可配置的通缩销毁机制
 * - 所有权管理
 * 
 * 通缩机制：
 * 1. 每日可执行销毁（24小时冷却）
 * 2. 销毁比例可配置（默认2%）
 * 3. 销毁分配：50%永久销毁，50%转入奖励池
 * 4. 可暂停/恢复销毁功能
 * 
 * 注意：销毁机制从代币总供应量中计算销毁量，不需要合约持有代币
 */
contract PaulToken is ERC20, Ownable {

    /**
     * @dev 代币总供应量上限
     * 注意：这里没有硬性上限，但可以通过铸造限制来管理
     */
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 10**18; // 1万亿，预留扩展空间

    // 销毁相关常量
    uint256 public constant ONE_DAY = 86400; // 24小时（秒）
    uint256 public constant BURN_DENOMINATOR = 100; // 百分比分母
    uint256 public constant BURN_TO_ZERO_RATIO = 50; // 50%转入零地址永久销毁
    uint256 public constant BURN_TO_REWARD_RATIO = 50; // 50%转入奖励池
    
    // 销毁配置
    uint256 public burnPercent = 2; // 默认销毁比例 2%
    address public rewardPool;      // 奖励池地址
    bool public burnEnabled = true; // 销毁功能开关
    
    // 销毁状态
    uint256 public lastBurnTime;    // 上次销毁时间戳
    
    // 销毁统计
    uint256 public totalBurned;     // 总销毁量
    uint256 public totalBurnedToZero; // 永久销毁到零地址的数量
    uint256 public totalSentToRewardPool; // 发送到奖励池的数量
    
    // 销毁相关事件
    event BurnExecuted(
        address indexed executor,
        uint256 burnAmount,
        uint256 burnedToZero,
        uint256 sentToRewardPool,
        uint256 timestamp
    );
    event BurnPercentUpdated(uint256 oldPercent, uint256 newPercent);
    event RewardPoolUpdated(address oldPool, address newPool);
    event BurnToggled(bool enabled);
    
    // 原有铸造事件
    event Mint(address indexed to, uint256 amount);
    
    /**
     * @dev 构造函数
     * 初始化代币并设置默认销毁参数
     * 
     * @PaulTokenram _initialRewardPool 初始奖励池地址
     */
    constructor(address _initialRewardPool) 
        ERC20("PaulTokenul Bailey Token", "PaulTokenUL") 
        Ownable(msg.sender)
    {
        // 基础检查
        require(_initialRewardPool != address(0), "PaulToken: reward pool cannot be zero address");
        
        // 设置初始奖励池
        rewardPool = _initialRewardPool;
        
        // 设置初始销毁时间为部署时间
        lastBurnTime = block.timestamp;
        
        // 铸造初始供应量
        uint256 initialSupply = 100_000_000_000 * 10**decimals();
        _mint(msg.sender, initialSupply);
        
        emit Mint(msg.sender, initialSupply);
    }
    
    /**
     * @dev 执行销毁功能
     * 只有所有者可以调用，需要满足时间锁定条件
     * 必须确保销毁功能已启用
     * 
     * 销毁逻辑：
     * 1. 计算当前总供应量
     * 2. 根据销毁比例计算销毁总量
     * 3. 分配销毁：50%永久销毁，50%转入奖励池
     * 4. 永久销毁：从总供应量中扣除
     * 5. 奖励池：从合约部署者地址转账给奖励池
     * 
     * 注意：销毁不要求合约持有代币，而是从总供应量中扣除
     */
    function executeBurn() external onlyOwner {
        // 检查销毁功能是否启用
        require(burnEnabled, "PaulToken: burn function is disabled");
        
        // 检查时间锁定（至少间隔24小时）
        require(
            block.timestamp >= lastBurnTime + ONE_DAY,
            "PaulToken: cannot execute burn yet, 24h cooldown required"
        );
        
        // 获取当前总供应量
        uint256 currentSupply = totalSupply();
        require(currentSupply > 0, "PaulToken: no tokens to burn");
        
        // 计算销毁总量
        uint256 burnAmount = (currentSupply * burnPercent) / BURN_DENOMINATOR;
        require(burnAmount > 0, "PaulToken: burn amount is zero");
        
        // 计算分配金额
        uint256 burnToZero = (burnAmount * BURN_TO_ZERO_RATIO) / 100;
        uint256 burnToReward = (burnAmount * BURN_TO_REWARD_RATIO) / 100;
        
        // 验证分配比例总和等于销毁总量
        require(
            burnToZero + burnToReward == burnAmount,
            "PaulToken: burn distribution calculation error"
        );
        
        // 执行永久销毁 - 从总供应量中扣除
        if (burnToZero > 0) {
            // 调用内部_burn函数，从零地址销毁（实际上是从总供应量中减少）
            // 注意：这里实际上是从零地址"销毁"，但零地址没有余额
            // 更好的做法是直接减少总供应量，但ERC20的_burn函数需要从有余额的地址销毁
            // 解决方案：从owner地址转账到零地址来实现永久销毁
            _transfer(owner(), address(0), burnToZero);
        }
        
        // 执行奖励池分配 - 从owner地址转账给奖励池
        if (burnToReward > 0) {
            _transfer(owner(), rewardPool, burnToReward);
        }
        
        // 更新销毁统计
        totalBurned += burnAmount;
        totalBurnedToZero += burnToZero;
        totalSentToRewardPool += burnToReward;
        
        // 更新上次销毁时间
        lastBurnTime = block.timestamp;
        
        // 触发事件
        emit BurnExecuted(
            msg.sender,
            burnAmount,
            burnToZero,
            burnToReward,
            block.timestamp
        );
    }
    
    /**
     * @dev 获取下次可执行销毁的时间
     * @return 下次可销毁的时间戳
     */
    function nextBurnTime() external view returns (uint256) {
        return lastBurnTime + ONE_DAY;
    }
    
    /**
     * @dev 获取当前可销毁的金额
     * @return burnToZero 转入零地址的金额
     * @return burnToReward 转入奖励池的金额
     */
    function getBurnableAmounts() external view returns (uint256 burnToZero, uint256 burnToReward) {
        uint256 currentSupply = totalSupply();
        uint256 burnAmount = (currentSupply * burnPercent) / BURN_DENOMINATOR;
        
        burnToZero = (burnAmount * BURN_TO_ZERO_RATIO) / 100;
        burnToReward = (burnAmount * BURN_TO_REWARD_RATIO) / 100;
        
        return (burnToZero, burnToReward);
    }
    
    /**
     * @dev 设置销毁比例
     * 只有所有者可以调用
     * 比例范围：1-10%（防止误操作设置过高比例）
     * 
     * @PaulTokenram _percent 新的销毁比例（1-10）
     */
    function setBurnPercent(uint256 _percent) external onlyOwner {
        require(_percent >= 1 && _percent <= 10, "PaulToken: burn percent must be 1-10");
        require(_percent != burnPercent, "PaulToken: same burn percent");
        
        uint256 oldPercent = burnPercent;
        burnPercent = _percent;
        
        emit BurnPercentUpdated(oldPercent, _percent);
    }
    
    /**
     * @dev 设置奖励池地址
     * 只有所有者可以调用
     * 不能设置为零地址
     * 
     * @PaulTokenram _pool 新的奖励池地址
     */
    function setRewardPool(address _pool) external onlyOwner {
        require(_pool != address(0), "PaulToken: reward pool cannot be zero address");
        require(_pool != rewardPool, "PaulToken: same reward pool");
        
        address oldPool = rewardPool;
        rewardPool = _pool;
        
        emit RewardPoolUpdated(oldPool, _pool);
    }
    
    /**
     * @dev 切换销毁功能开关
     * 只有所有者可以调用
     * 紧急情况下可以暂停销毁功能
     * 
     * @PaulTokenram _enable true启用销毁，false禁用销毁
     */
    function toggleBurn(bool _enable) external onlyOwner {
        require(_enable != burnEnabled, "PaulToken: same state");
        
        burnEnabled = _enable;
        
        emit BurnToggled(_enable);
    }
    
    /**
     * @dev 获取销毁状态信息
     * @return _burnPercent 当前销毁比例
     * @return _lastBurnTime 上次销毁时间戳
     * @return _nextBurnTime 下次可销毁时间戳
     * @return _rewardPool 奖励池地址
     * @return _burnEnabled 销毁功能是否启用
     * @return _totalBurned 总销毁量
     * @return _totalBurnedToZero 永久销毁到零地址的数量
     * @return _totalSentToRewardPool 发送到奖励池的数量
     */
    function getBurnInfo() external view returns (
        uint256 _burnPercent,
        uint256 _lastBurnTime,
        uint256 _nextBurnTime,
        address _rewardPool,
        bool _burnEnabled,
        uint256 _totalBurned,
        uint256 _totalBurnedToZero,
        uint256 _totalSentToRewardPool
    ) {
        return (
            burnPercent,
            lastBurnTime,
            lastBurnTime + ONE_DAY,
            rewardPool,
            burnEnabled,
            totalBurned,
            totalBurnedToZero,
            totalSentToRewardPool
        );
    }
    
    // 原有铸造功能
    function mint(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "PaulToken: cannot mint to zero address");
        require(amount > 0, "PaulToken: mint amount must be greater than zero");
        
        // 检查总供应量上限
        require(
            totalSupply() + amount <= MAX_SUPPLY,
            "PaulToken: mint amount exceeds max supply"
        );
        
        _mint(to, amount);
        emit Mint(to, amount);
    }
    
    // 原有批量铸造功能
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner {
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
    
    // 原有版本函数
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
    
    // 原有精度函数
    function decimals() public pure override returns (uint8) {
        return 18;
    }
    
    // 原有转账函数（保持不变）
    function transfer(address to, uint256 value) public override returns (bool) {
        require(to != address(0), "PaulToken: transfer to zero address");
        require(value > 0, "PaulToken: transfer value must be greater than zero");
        
        return super.transfer(to, value);
    }
    
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        require(from != address(0), "PaulToken: transfer from zero address");
        require(to != address(0), "PaulToken: transfer to zero address");
        require(value > 0, "PaulToken: transfer value must be greater than zero");
        
        return super.transferFrom(from, to, value);
    }
}