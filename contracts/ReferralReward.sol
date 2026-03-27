// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ReferralReward is Ownable, ReentrancyGuard {
    
    // --- 常量 ---
    uint256 public constant MIN_VALID_USER_AMOUNT = 100 * 10**18; // 有效用户门槛 100U
    uint256 public constant MAX_GENERATION = 3; // 最大代数 3代
    uint256 public constant TOTAL_LEVELS = 9; // G1-G9 共9个等级
    
    // --- 等级配置 ---
    struct LevelConfig {
        uint256 teamPerformance; // 小区业绩要求
        uint256 rewardRate;      // 奖励比例 (百分比，如10% = 1000)
    }
    
    // 等级映射表 (G1-G9)
    LevelConfig[TOTAL_LEVELS] public levelConfigs;
    
    // --- 用户数据结构 ---
    struct UserInfo {
        address referrer;                    // 上级地址
        uint256 totalTeamPerformance;        // 团队总业绩
        uint256 smallTeamPerformance;        // 小区业绩（用于计算等级）
        uint256[] directReferrals;           // 直推用户地址列表
        uint256 level;                       // 当前等级 (0=无等级, 1=G1, ..., 9=G9)
        bool isValidUser;                    // 是否为有效用户（≥100U）
        uint256 pendingStaticRewards;        // 待领取的静态收益代数奖
        uint256 pendingLevelRewards;         // 待领取的动态等级奖
        uint256 lastUpdateTime;              // 上次更新时间
    }
    
    // 代数奖比例 (1代:10%, 2代:5%, 3代:2%)
    uint256[3] public generationRewardRates = [1000, 500, 200]; // 单位: 基点 (1000=10%)
    
    // 同级奖励比例 10%
    uint256 public constant PEER_REWARD_RATE = 1000; // 10%
    
    // --- 状态变量 ---
    mapping(address => UserInfo) public users;
    mapping(address => bool) public isRegistered;
    
    // 授权调用者（质押合约）
    mapping(address => bool) public authorizedCallers;
    
    // 全局统计
    uint256 public totalUsers;
    uint256 public totalValidUsers;
    
    // 代币地址（用于奖励发放）
    IERC20 public rewardToken;
    
    // --- 事件 ---
    event ReferrerBound(address indexed user, address indexed referrer);
    event TeamPerformanceUpdated(address indexed user, int256 amountChange, uint256 newTotal, uint256 newSmall);
    event LevelUpgraded(address indexed user, uint256 oldLevel, uint256 newLevel);
    event StaticRewardDistributed(
        address indexed user, 
        address[] receivers, 
        uint256[] amounts, 
        uint256[] generations
    );
    event LevelRewardClaimed(address indexed user, uint256 amount, uint256 level);
    event StaticRewardClaimed(address indexed user, uint256 amount);
    event AuthorizedCallerSet(address indexed caller, bool authorized);
    
    // --- 修饰器 ---
    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    modifier userExists(address user) {
        require(isRegistered[user], "User not registered");
        _;
    }
    
    // --- 构造函数 ---
    constructor(address _rewardToken, address _initialOwner) Ownable(_initialOwner) {
        require(_rewardToken != address(0), "Invalid token address");
        rewardToken = IERC20(_rewardToken);
        
        // 初始化等级配置 (文档中的G1-G9)
        _initializeLevelConfigs();
    }
    
    // --- 核心功能 1: 关系绑定 (紧缩机制) ---
    function bindReferrer(address referrerCode) external {
        require(!isRegistered[msg.sender], "Already registered");
        require(referrerCode != address(0), "Invalid referrer");
        require(referrerCode != msg.sender, "Cannot refer self");
        require(isRegistered[referrerCode], "Referrer not registered");
        
        // 检查循环引用
        _checkNoCycle(msg.sender, referrerCode);
        
        // 注册用户
        isRegistered[msg.sender] = true;
        users[msg.sender].referrer = referrerCode;
        users[msg.sender].lastUpdateTime = block.timestamp;
        users[msg.sender].level = 0; // 初始无等级
        
        // 添加到上级的直接推荐列表
        users[referrerCode].directReferrals.push(uint256(uint160(msg.sender)));
        
        totalUsers++;
        
        emit ReferrerBound(msg.sender, referrerCode);
    }
    
    // 检查循环引用
    function _checkNoCycle(address newUser, address referrer) internal view {
        address current = referrer;
        while (current != address(0)) {
            require(current != newUser, "Cycle detected");
            current = users[current].referrer;
        }
    }
    
    // --- 核心功能 2: 数据存储与计算 (Gas优化关键) ---
    function updateTeamPerformance(
        address user, 
        int256 amountChange, 
        bool isDeposit
    ) external onlyAuthorized userExists(user) {
        UserInfo storage userInfo = users[user];
        
        // 更新有效用户状态
        if (isDeposit && !userInfo.isValidUser) {
            // 检查是否达到有效用户门槛
            // 注意：这里需要知道用户总入金额，需要从外部传入或计算
            // 简化处理：每次入金都检查
        }
        
        // 更新用户自身的业绩 - 使用原生算术运算
        if (amountChange > 0) {
            userInfo.totalTeamPerformance = userInfo.totalTeamPerformance + uint256(amountChange);
        } else if (amountChange < 0) {
            uint256 change = uint256(-amountChange);
            if (change > userInfo.totalTeamPerformance) {
                userInfo.totalTeamPerformance = 0;
            } else {
                userInfo.totalTeamPerformance = userInfo.totalTeamPerformance - change;
            }
        }
        
        // 更新用户等级
        _updateUserLevel(user);
        
        // 递归更新上级业绩（使用迭代而非递归以节省Gas）
        _updateAncestorsPerformance(user, amountChange, isDeposit);
        
        emit TeamPerformanceUpdated(
            user, 
            amountChange, 
            userInfo.totalTeamPerformance, 
            userInfo.smallTeamPerformance
        );
    }
    
    // Gas优化：使用迭代而非递归更新祖先业绩
    function _updateAncestorsPerformance(
        address user, 
        int256 amountChange, 
        bool isDeposit
    ) internal {
        address currentReferrer = users[user].referrer;
        uint256 depth = 0;
        
        // 只更新最多3代（根据代数奖设置）
        while (currentReferrer != address(0) && depth < MAX_GENERATION) {
            UserInfo storage referrerInfo = users[currentReferrer];
            
            // 更新团队总业绩 - 使用原生算术运算
            if (amountChange > 0) {
                referrerInfo.totalTeamPerformance = referrerInfo.totalTeamPerformance + uint256(amountChange);
            } else if (amountChange < 0) {
                uint256 change = uint256(-amountChange);
                if (change > referrerInfo.totalTeamPerformance) {
                    referrerInfo.totalTeamPerformance = 0;
                } else {
                    referrerInfo.totalTeamPerformance = referrerInfo.totalTeamPerformance - change;
                }
            }
            
            // 更新小区业绩（紧缩机制的关键实现）
            // 小区业绩 = 所有直推用户的业绩，排除最大的那条线
            if (isDeposit) {
                _updateSmallTeamPerformance(currentReferrer, user, uint256(amountChange), amountChange > 0);
            }
            
            // 更新上级等级
            _updateUserLevel(currentReferrer);
            
            // 移动到上一级
            currentReferrer = referrerInfo.referrer;
            depth++;
        }
    }
    
    // 更新小区业绩（实现紧缩机制）- 使用原生算术运算
    function _updateSmallTeamPerformance(
        address referrer, 
        address updatedChild,
        uint256 amount,
        bool isIncrease
    ) internal {
        UserInfo storage referrerInfo = users[referrer];
        address[] memory children = _getDirectReferrals(referrer);
        
        if (children.length <= 1) {
            // 如果只有0或1个直推，小区业绩就是该直推的业绩
            if (isIncrease) {
                referrerInfo.smallTeamPerformance = referrerInfo.smallTeamPerformance + amount;
            } else {
                if (amount > referrerInfo.smallTeamPerformance) {
                    referrerInfo.smallTeamPerformance = 0;
                } else {
                    referrerInfo.smallTeamPerformance = referrerInfo.smallTeamPerformance - amount;
                }
            }
            return;
        }
        
        // 找到最大的直推业绩线
        uint256 maxPerformance = 0;
        address maxChild = address(0);
        
        for (uint256 i = 0; i < children.length; i++) {
            address child = children[i];
            uint256 childPerf = users[child].totalTeamPerformance;
            
            // 如果是当前更新的用户，使用新值
            if (child == updatedChild) {
                if (isIncrease) {
                    childPerf = childPerf + amount;
                } else {
                    childPerf = childPerf > amount ? childPerf - amount : 0;
                }
            }
            
            if (childPerf > maxPerformance) {
                maxPerformance = childPerf;
                maxChild = child;
            }
        }
        
        // 计算小区业绩（排除最大的那条线）- 使用原生算术运算
        uint256 newSmallTeamPerformance = 0;
        for (uint256 i = 0; i < children.length; i++) {
            address child = children[i];
            if (child != maxChild) {
                uint256 childPerf = users[child].totalTeamPerformance;
                if (child == updatedChild) {
                    if (isIncrease) {
                        childPerf = childPerf + amount;
                    } else {
                        childPerf = childPerf > amount ? childPerf - amount : 0;
                    }
                }
                newSmallTeamPerformance = newSmallTeamPerformance + childPerf;
            }
        }
        
        referrerInfo.smallTeamPerformance = newSmallTeamPerformance;
    }
    
    // --- 核心功能 3: 静态收益代数奖 ---
    function distributeStaticReward(
        address user, 
        uint256 rewardAmount
    ) external onlyAuthorized userExists(user) returns (uint256 totalDistributed) {
        require(rewardAmount > 0, "Invalid reward amount");
        
        address current = user;
        address[] memory receivers = new address[](MAX_GENERATION);
        uint256[] memory amounts = new uint256[](MAX_GENERATION);
        uint256[] memory generations = new uint256[](MAX_GENERATION);
        
        uint256 distributedCount = 0;
        
        // 向上查找1-3代有效上级
        for (uint256 i = 0; i < MAX_GENERATION; i++) {
            current = users[current].referrer;
            
            if (current == address(0)) {
                break; // 没有更多上级
            }
            
            // 检查是否为有效用户
            if (!users[current].isValidUser) {
                continue; // 紧缩机制：空点位不计算
            }
            
            // 计算奖励金额 - 使用原生算术运算
            uint256 reward = (rewardAmount * generationRewardRates[i]) / 10000;
            
            if (reward > 0) {
                // 累积到上级的待领取奖励 - 使用原生算术运算
                users[current].pendingStaticRewards = users[current].pendingStaticRewards + reward;
                
                receivers[distributedCount] = current;
                amounts[distributedCount] = reward;
                generations[distributedCount] = i + 1; // 1代, 2代, 3代
                distributedCount++;
                
                totalDistributed = totalDistributed + reward;
            }
        }
        
        // 发射事件
        if (distributedCount > 0) {
            // 调整数组大小
            address[] memory actualReceivers = new address[](distributedCount);
            uint256[] memory actualAmounts = new uint256[](distributedCount);
            uint256[] memory actualGenerations = new uint256[](distributedCount);
            
            for (uint256 i = 0; i < distributedCount; i++) {
                actualReceivers[i] = receivers[i];
                actualAmounts[i] = amounts[i];
                actualGenerations[i] = generations[i];
            }
            
            emit StaticRewardDistributed(user, actualReceivers, actualAmounts, actualGenerations);
        }
        
        return totalDistributed;
    }
    
    // --- 核心功能 4: 动态收益等级奖 ---
    function claimLevelReward(address user) external nonReentrant userExists(user) returns (uint256) {
        UserInfo storage userInfo = users[user];
        require(userInfo.level > 0, "No level");
        
        
        // 获取用户的等级奖励比例
        uint256 userRewardRate = levelConfigs[userInfo.level - 1].rewardRate;
        
        uint256 totalReward = 0;
        
        // 遍历所有直推用户
        for (uint256 i = 0; i < userInfo.directReferrals.length; i++) {
            address child = address(uint160(userInfo.directReferrals[i]));
            UserInfo storage childInfo = users[child];
            
            // 计算下级的静态收益
            uint256 childStaticRewards = _getUserStaticRewards(child);
            
            if (childStaticRewards == 0) {
                continue;
            }
            
            // 级差烧伤逻辑
            if (childInfo.level < userInfo.level) {
                // 下级等级低，计算级差 - 使用原生算术运算
                uint256 childRewardRate = childInfo.level > 0 ? 
                    levelConfigs[childInfo.level - 1].rewardRate : 0;
                uint256 rateDiff = userRewardRate - childRewardRate;
                
                if (rateDiff > 0) {
                    uint256 reward = (childStaticRewards * rateDiff) / 10000;
                    totalReward = totalReward + reward;
                }
            } else if (childInfo.level == userInfo.level) {
                // 同级奖励 10% - 使用原生算术运算
                uint256 reward = (childStaticRewards * PEER_REWARD_RATE) / 10000;
                totalReward = totalReward + reward;
            }
            // 下级等级更高，不获得奖励
        }
        
        require(totalReward > 0, "No level reward to claim");
        
        // 更新待领取奖励 - 使用原生算术运算
        userInfo.pendingLevelRewards = userInfo.pendingLevelRewards + totalReward;
        
        // 转账奖励
        uint256 toTransfer = userInfo.pendingLevelRewards;
        require(rewardToken.transfer(user, toTransfer), "Transfer failed");
        
        // 清零待领取
        userInfo.pendingLevelRewards = 0;
        
        emit LevelRewardClaimed(user, toTransfer, userInfo.level);
        
        return toTransfer;
    }
    
    function claimStaticReward() external nonReentrant userExists(msg.sender) returns (uint256) {
        UserInfo storage userInfo = users[msg.sender];
        require(userInfo.pendingStaticRewards > 0, "No static reward to claim");
        
        uint256 amount = userInfo.pendingStaticRewards;
        userInfo.pendingStaticRewards = 0;
        
        require(rewardToken.transfer(msg.sender, amount), "Transfer failed");
        
        emit StaticRewardClaimed(msg.sender, amount);
        
        return amount;
    }
    
    // --- 辅助函数 ---
    function _initializeLevelConfigs() internal {
        // 文档中的等级配置
        levelConfigs[0] = LevelConfig(10000 * 10**18, 1000);  // G1: 10,000U, 10%
        levelConfigs[1] = LevelConfig(30000 * 10**18, 2000);  // G2: 30,000U, 20%
        levelConfigs[2] = LevelConfig(100000 * 10**18, 3000); // G3: 100,000U, 30%
        levelConfigs[3] = LevelConfig(300000 * 10**18, 4000); // G4: 300,000U, 40%
        levelConfigs[4] = LevelConfig(1000000 * 10**18, 5000); // G5: 1,000,000U, 50%
        levelConfigs[5] = LevelConfig(3000000 * 10**18, 6000); // G6: 3,000,000U, 60%
        levelConfigs[6] = LevelConfig(10000000 * 10**18, 7000); // G7: 10,000,000U, 70%
        levelConfigs[7] = LevelConfig(30000000 * 10**18, 8000); // G8: 30,000,000U, 80%
        levelConfigs[8] = LevelConfig(100000000 * 10**18, 9000); // G9: 100,000,000U, 90%
    }
    
    function _updateUserLevel(address user) internal {
        UserInfo storage userInfo = users[user];
        uint256 newLevel = 0;
        
        // 检查用户符合哪个等级
        for (uint256 i = TOTAL_LEVELS; i > 0; i--) {
            if (userInfo.smallTeamPerformance >= levelConfigs[i-1].teamPerformance) {
                newLevel = i;
                break;
            }
        }
        
        // 如果等级发生变化
        if (newLevel != userInfo.level) {
            uint256 oldLevel = userInfo.level;
            userInfo.level = newLevel;
            
            if (newLevel > oldLevel) {
                emit LevelUpgraded(user, oldLevel, newLevel);
            }
        }
    }
    
    function _calculateTotalStaticUnder(address user) internal view returns (uint256) {
        // 递归计算伞下所有用户的静态收益
        // 注意：这是一个递归函数，在链上计算可能消耗大量Gas
        // 实际实现应考虑链下计算或使用累加器
        uint256 total = users[user].pendingStaticRewards;
        
        for (uint256 i = 0; i < users[user].directReferrals.length; i++) {
            address child = address(uint160(users[user].directReferrals[i]));
            total = total + _calculateTotalStaticUnder(child);
        }
        
        return total;
    }
    
    function _getUserStaticRewards(address user) internal view returns (uint256) {
        // 获取用户的静态收益
        // 这里需要与质押合约交互，获取真实的静态收益
        // 简化实现：返回待领取奖励
        return users[user].pendingStaticRewards;
    }
    
    function _getDirectReferrals(address user) internal view returns (address[] memory) {
        uint256 length = users[user].directReferrals.length;
        address[] memory referrals = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            referrals[i] = address(uint160(users[user].directReferrals[i]));
        }
        
        return referrals;
    }
    
    // 用户撤资时清零贡献值的回调
    function onWithdrawClearContribution(address user) external onlyAuthorized {
        // 用户撤资时，其贡献值被清零
        // 这里可以更新相关状态
        users[user].isValidUser = false;
        // 可能需要重新计算上级的团队业绩
    }
    
    // --- 管理功能 ---
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit AuthorizedCallerSet(caller, authorized);
    }
    
    function setRewardToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token");
        rewardToken = IERC20(token);
    }
    
    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }
    
    // --- 视图函数 ---
    function getUserReferrals(address user) external view returns (address[] memory) {
        return _getDirectReferrals(user);
    }
    
    function getGenerationReward(address user, uint256 generation) external view returns (uint256) {
        require(generation >= 1 && generation <= 3, "Invalid generation");
        return users[user].pendingStaticRewards;
    }
    
    function getPendingRewards(address user) external view returns (
        uint256 staticRewards, 
        uint256 levelRewards, 
        uint256 totalRewards
    ) {
        UserInfo storage userInfo = users[user];
        staticRewards = userInfo.pendingStaticRewards;
        levelRewards = userInfo.pendingLevelRewards;
        totalRewards = staticRewards + levelRewards;
    }
    
    function getUserLevelInfo(address user) external view returns (
        uint256 level,
        uint256 smallTeamPerformance,
        uint256 totalTeamPerformance,
        uint256 requiredForNextLevel
    ) {
        UserInfo storage userInfo = users[user];
        level = userInfo.level;
        smallTeamPerformance = userInfo.smallTeamPerformance;
        totalTeamPerformance = userInfo.totalTeamPerformance;
        
        uint256 nextLevelReq = 0;
        if (level < TOTAL_LEVELS) {
            nextLevelReq = levelConfigs[level].teamPerformance;
        }
        
        return (level, smallTeamPerformance, totalTeamPerformance, nextLevelReq);
    }
}