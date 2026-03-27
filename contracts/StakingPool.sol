// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IPaulBaileyToken {
    /// @notice 查询账户余额
    function balanceOf(address account) external view returns (uint256);
    
    /// @notice 卖出保罗币换取USD1
    function sell(uint256 tokenAmount) external;
    
    /// @notice 特殊奖励铸造函数（需要在PaulBaileyToken合约中实现）
    function mintReward(address to, uint256 amount) external;
}

interface IReferralReward {
    /// @notice 更新用户团队业绩
    function updateTeamPerformance(address user, int256 amountChange, bool isDeposit) external;
    
    /// @notice 用户提现时清除贡献值
    function onWithdrawClearContribution(address user) external;
}

/// @title 保罗币质押池
/// @notice 用户质押USD1获得贡献值，贡献值每日衰减1%，可领取保罗币奖励
/// @dev 保罗币不可转账，奖励通过特殊铸造机制分配
contract StakingPool is ReentrancyGuard, Ownable {
    
    // ============ 常量定义 ============
    
    /// @notice 最小质押金额：100 USD1（假设18位小数）
    uint256 public constant MIN_DEPOSIT = 100 * 10**18;
    
    /// @notice 每日衰减率：1%（以基点表示）
    uint256 public constant DAILY_DECAY_BPS = 100;
    
    /// @notice 每天秒数
    uint256 public constant SECONDS_PER_DAY = 86400;
    
    /// @notice 未领取奖励过期时间：24小时
    uint256 public constant UNCLAIM_EXPIRE_TIME = 86400;
    
    // ============ 状态变量 ============
    
    /// @notice USD1代币合约（如USDT）
    IERC20 public immutable usdToken;
    
    /// @notice 保罗币合约
    IPaulBaileyToken public immutable pblToken;
    
    /// @notice 推荐奖励合约
    IReferralReward public referralContract;
    
    /// @notice 用户质押信息
    struct UserStake {
        uint256 principal;           // 本金余额（USD1）
        uint256 contribution;        // 当前贡献值
        uint256 lastUpdateTime;      // 上次更新时间戳
        uint256 lastClaimTime;       // 上次领取奖励时间戳
        uint256 lockUntil;           // 本金锁定到期时间
        uint256 pendingRewards;      // 待领取奖励（保罗币数量）
        uint256 contributionSnapshot; // 用于衰减计算的贡献值快照
        uint256 globalDecayFactorSnapshot; // 记录时的全局衰减系数
    }
    
    /// @notice 全局衰减系数（18位小数精度），初始为1
    uint256 public globalDecayFactor = 1e18;
    
    /// @notice 上次全局衰减更新时间戳
    uint256 public lastGlobalDecayUpdate;
    
    /// @notice 全局有效贡献值总和（已考虑衰减）
    uint256 public totalActiveContribution;
    
    /// @notice 用户质押信息映射
    mapping(address => UserStake) public userStakes;
    
    /// @notice 待分配奖励总量（保罗币数量）
    uint256 public totalRewardToDistribute;
    
    /// @notice 上次奖励分配时间戳
    uint256 public lastRewardDistributionTime;
    
    /// @notice 私募合约地址（来自此地址的质押贡献值翻倍）
    address public privateSaleContract;
    
    /// @notice 私募贡献值倍数
    uint256 public privateSaleMultiplier = 3;
    
    // ============ 事件定义 ============
    
    /// @notice 用户质押事件
    event Deposited(address indexed user, uint256 usdAmount, uint256 principal, uint256 contributionAdded, uint256 lockUntil);
    
    /// @notice 奖励分配事件
    event RewardsDistributed(uint256 totalAmount);
    
    /// @notice 奖励领取事件
    event RewardsClaimed(address indexed user, uint256 amount);
    
    /// @notice 本金提现事件
    event PrincipalWithdrawn(address indexed user, uint256 amount);
    
    /// @notice 私募地址设置事件
    event PrivateSaleSet(address indexed contractAddress);
    
    /// @notice 推荐合约设置事件
    event ReferralContractSet(address indexed contractAddress);
    
    /// @notice 每日衰减应用事件
    event DailyDecayApplied(uint256 newGlobalDecayFactor, uint256 timestamp);
    
    // ============ 构造函数 ============
    
    /// @notice 初始化质押池
    /// @param _usdToken USD1代币地址
    /// @param _pblToken 保罗币地址
    /// @param _initialOwner 合约所有者
    constructor(
        address _usdToken,
        address _pblToken,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_usdToken != address(0) && _pblToken != address(0), "Zero address");
        usdToken = IERC20(_usdToken);
        pblToken = IPaulBaileyToken(_pblToken);
        lastGlobalDecayUpdate = block.timestamp;
    }
    
    // ============ 核心功能：质押 ============
    
    /// @notice 用户质押USD1
    /// @dev 质押金额需为100 USD1的整数倍
    /// @param usdtAmount 质押的USD1数量
    function deposit(uint256 usdtAmount) external nonReentrant {
        require(usdtAmount >= MIN_DEPOSIT, "Below minimum deposit");
        require(usdtAmount % (100 * 10**18) == 0, "Must be multiple of 100");
        
        // 更新用户衰减状态
        _updateUserDecay(msg.sender);
        
        // 接收用户USD1
        require(usdToken.transferFrom(msg.sender, address(this), usdtAmount), "Transfer failed");
        
        // 计算资金分配：30%用于流动性，70%作为本金
        uint256 toLiquidity = (usdtAmount * 30) / 100;
        uint256 toPrincipal = usdtAmount - toLiquidity;
        
        // 添加流动性（简化实现）
        _addToLiquidity(toLiquidity);
        
        // 记录用户本金
        userStakes[msg.sender].principal += toPrincipal;
        
        // 设置或延长锁定期
        if (userStakes[msg.sender].lockUntil < block.timestamp) {
            userStakes[msg.sender].lockUntil = block.timestamp + 24 hours;
        } else {
            userStakes[msg.sender].lockUntil += 24 hours;
        }
        
        // 计算贡献值
        uint256 contributionToAdd = usdtAmount;
        if (privateSaleContract != address(0) && msg.sender == privateSaleContract) {
            contributionToAdd *= privateSaleMultiplier;
        }
        
        // 更新贡献值
        _addContribution(msg.sender, contributionToAdd);
        
        // 更新推荐系统业绩
        if (address(referralContract) != address(0)) {
            referralContract.updateTeamPerformance(msg.sender, int256(usdtAmount), true);
        }
        
        emit Deposited(
            msg.sender, 
            usdtAmount, 
            toPrincipal, 
            contributionToAdd, 
            userStakes[msg.sender].lockUntil
        );
    }
    
    // ============ 核心功能：提现 ============
    
    /// @notice 用户提现本金
    /// @dev 本金解锁后才可提现，提现后贡献值清零
    /// @param amount 提现金额
    function withdrawPrincipal(uint256 amount) external nonReentrant {
        require(amount > 0, "Cannot withdraw zero");
        
        UserStake storage user = userStakes[msg.sender];
        require(block.timestamp >= user.lockUntil, "Funds are locked");
        require(user.principal >= amount, "Insufficient principal");
        
        // 更新用户衰减状态
        _updateUserDecay(msg.sender);
        
        // 扣除本金
        user.principal -= amount;
        
        // 贡献值清零
        _clearContribution(msg.sender);
        
        // 更新推荐系统
        if (address(referralContract) != address(0)) {
            referralContract.onWithdrawClearContribution(msg.sender);
            referralContract.updateTeamPerformance(msg.sender, -int256(amount), false);
        }
        
        // 转账给用户
        require(usdToken.transfer(msg.sender, amount), "Transfer failed");
        
        emit PrincipalWithdrawn(msg.sender, amount);
    }
    
    /// @notice 查询用户可提现本金
    /// @param user 用户地址
    /// @return 可提现金额
    function getWithdrawablePrincipal(address user) external view returns (uint256) {
        UserStake storage stake = userStakes[user];
        if (block.timestamp >= stake.lockUntil) {
            return stake.principal;
        }
        return 0;
    }
    
    // ============ 贡献值系统 ============
    
    /// @dev 更新全局衰减系数
    /// @notice 每日衰减1%，使用快速幂算法计算
    function _updateGlobalDecay() internal {
        uint256 timePassed = block.timestamp - lastGlobalDecayUpdate;
        if (timePassed < SECONDS_PER_DAY) {
            return;
        }
        
        uint256 daysPassed = timePassed / SECONDS_PER_DAY;
        if (daysPassed == 0) return;
        
        // 计算 (0.99)^daysPassed
        uint256 base = 9900; // 0.99 * 10000
        uint256 exponent = daysPassed;
        uint256 result = 1e18;
        
        // 快速幂算法
        while (exponent > 0) {
            if (exponent % 2 == 1) {
                result = (result * base) / 10000;
            }
            base = (base * base) / 10000;
            exponent = exponent / 2;
        }
        
        globalDecayFactor = result;
        lastGlobalDecayUpdate = block.timestamp;
        
        // 更新总贡献值
        totalActiveContribution = (totalActiveContribution * globalDecayFactor) / 1e18;
        
        emit DailyDecayApplied(globalDecayFactor, block.timestamp);
    }
    
    /// @dev 更新用户衰减状态
    /// @param user 用户地址
    function _updateUserDecay(address user) internal {
        _updateGlobalDecay();
        
        UserStake storage stake = userStakes[user];
        if (stake.contribution == 0) return;
        
        // 应用衰减
        if (stake.contributionSnapshot > 0) {
            uint256 decayedContribution = (stake.contributionSnapshot * globalDecayFactor) / stake.globalDecayFactorSnapshot;
            
            // 更新贡献值
            totalActiveContribution = totalActiveContribution - stake.contribution + decayedContribution;
            stake.contribution = decayedContribution;
        }
        
        // 更新快照
        stake.contributionSnapshot = stake.contribution;
        stake.globalDecayFactorSnapshot = globalDecayFactor;
        stake.lastUpdateTime = block.timestamp;
    }
    
    /// @dev 增加用户贡献值
    /// @param user 用户地址
    /// @param amount 贡献值增量
    function _addContribution(address user, uint256 amount) internal {
        UserStake storage stake = userStakes[user];
        
        // 更新衰减
        if (stake.contribution > 0) {
            _updateUserDecay(user);
        } else {
            // 新用户初始化
            stake.contributionSnapshot = 0;
            stake.globalDecayFactorSnapshot = globalDecayFactor;
        }
        
        // 增加贡献值
        stake.contribution += amount;
        totalActiveContribution += amount;
        
        // 更新快照
        stake.contributionSnapshot = stake.contribution;
        stake.lastUpdateTime = block.timestamp;
    }
    
    /// @dev 清除用户贡献值
    /// @param user 用户地址
    function _clearContribution(address user) internal {
        UserStake storage stake = userStakes[user];
        
        if (stake.contribution > 0) {
            _updateUserDecay(user);
            totalActiveContribution -= stake.contribution;
            stake.contribution = 0;
            stake.contributionSnapshot = 0;
        }
    }
    
    /// @notice 手动触发更新衰减
    function updateDecay() external {
        _updateGlobalDecay();
    }
    
    // ============ 奖励系统 ============
    
    /// @notice 分配奖励（仅所有者可调用）
    /// @dev 保罗币通缩产生的奖励由此函数分配
    /// @param rewardAmount 奖励数量（保罗币）
    function distributeRewards(uint256 rewardAmount) external onlyOwner {
        require(rewardAmount > 0, "No reward to distribute");
        require(totalActiveContribution > 0, "No active contributors");
        
        _updateGlobalDecay();
        
        // 记录总奖励
        totalRewardToDistribute += rewardAmount;
        lastRewardDistributionTime = block.timestamp;
        
        emit RewardsDistributed(rewardAmount);
    }
    
    /// @notice 用户领取奖励
    /// @dev 奖励超过24小时未领取将过期作废
    function claimRewards() external nonReentrant {
        _updateUserDecay(msg.sender);
        
        UserStake storage stake = userStakes[msg.sender];
        require(stake.contribution > 0, "No contribution");
        require(totalActiveContribution > 0, "No total contribution");
        
        // 计算用户应得份额
        uint256 userShare = (stake.contribution * 1e18) / totalActiveContribution;
        uint256 pending = (totalRewardToDistribute * userShare) / 1e18;
        
        require(pending > 0, "No rewards to claim");
        
        // 检查过期
        if (stake.lastClaimTime > 0 && block.timestamp > stake.lastClaimTime + UNCLAIM_EXPIRE_TIME) {
            stake.pendingRewards = 0; // 过期作废
        } else {
            stake.pendingRewards += pending; // 累积奖励
        }
        
        uint256 toClaim = stake.pendingRewards;
        
        // 清零待领取
        stake.pendingRewards = 0;
        stake.lastClaimTime = block.timestamp;
        
        // 从总奖励中扣除
        totalRewardToDistribute -= toClaim;
        
        // 特殊铸造奖励给用户
        pblToken.mintReward(msg.sender, toClaim);
        
        emit RewardsClaimed(msg.sender, toClaim);
    }
    
    /// @notice 查询用户待领取奖励
    /// @param user 用户地址
    /// @return 待领取奖励数量
    function getPendingRewards(address user) external view returns (uint256) {
        UserStake storage stake = userStakes[user];
        
        if (stake.contribution == 0 || totalActiveContribution == 0) {
            return 0;
        }
        
        // 计算当前份额
        uint256 userShare = (stake.contribution * 1e18) / totalActiveContribution;
        uint256 pending = (totalRewardToDistribute * userShare) / 1e18;
        
        // 加上之前累积
        uint256 total = pending + stake.pendingRewards;
        
        // 检查过期
        if (stake.lastClaimTime > 0 && block.timestamp > stake.lastClaimTime + UNCLAIM_EXPIRE_TIME) {
            return 0;
        }
        
        return total;
    }
    
    // ============ 辅助功能 ============
    
    /// @dev 添加流动性（简化实现）
    /// @param usdAmount USD1数量
    function _addToLiquidity(uint256 usdAmount) internal {
        // 实际实现需要调用DEX Router添加流动性
        // 简化：转入所有者地址
        usdToken.transfer(owner(), usdAmount);
    }
    
    // ============ 管理功能 ============
    
    /// @notice 设置私募合约地址
    /// @param _privateSaleContract 私募合约地址
    function setPrivateSaleContract(address _privateSaleContract) external onlyOwner {
        privateSaleContract = _privateSaleContract;
        emit PrivateSaleSet(_privateSaleContract);
    }
    
    /// @notice 设置推荐合约
    /// @param _referralContract 推荐合约地址
    function setReferralContract(address _referralContract) external onlyOwner {
        referralContract = IReferralReward(_referralContract);
        emit ReferralContractSet(_referralContract);
    }
    
    /// @notice 设置私募贡献值倍数
    /// @param multiplier 倍数（必须≥1）
    function setPrivateSaleMultiplier(uint256 multiplier) external onlyOwner {
        require(multiplier >= 1, "Multiplier must be >= 1");
        privateSaleMultiplier = multiplier;
    }
    
    /// @notice 紧急提取代币
    /// @param token 代币地址
    /// @param amount 提取数量
    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }
    
    // ============ 视图函数 ============
    
    /// @notice 获取用户信息
    /// @param user 用户地址
    function getUserInfo(address user) external view returns (
        uint256 principal,
        uint256 contribution,
        uint256 lockUntil,
        uint256 pendingRewards,
        uint256 lastClaimTime
    ) {
        UserStake storage stake = userStakes[user];
        return (
            stake.principal,
            stake.contribution,
            stake.lockUntil,
            stake.pendingRewards,
            stake.lastClaimTime
        );
    }
    
    /// @notice 获取全局衰减信息
    function getGlobalDecayInfo() external view returns (
        uint256 decayFactor,
        uint256 lastUpdate,
        uint256 totalContribution
    ) {
        return (
            globalDecayFactor,
            lastGlobalDecayUpdate,
            totalActiveContribution
        );
    }
}