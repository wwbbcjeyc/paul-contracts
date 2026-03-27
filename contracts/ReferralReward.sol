// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStakingPool {
    function getUserInfo(address user) external view returns (
        uint256 principal,
        uint256 contribution,
        uint256 lockUntil,
        uint256 pendingRewards,
        uint256 lastClaimTime,
        uint256 totalDeposited
    );
}

contract ReferralReward is Ownable, ReentrancyGuard {
    
    uint256 public constant MIN_VALID_USER_AMOUNT = 100 * 10**18;
    uint256 public constant MAX_GENERATION = 3;
    uint256 public constant TOTAL_LEVELS = 9;
    
    struct LevelConfig {
        uint256 teamPerformance;
        uint256 rewardRate;
    }
    
    struct UserInfo {
        address referrer;
        uint256 totalTeamPerformance;
        uint256 smallTeamPerformance;
        address[] directReferrals;
        uint256 level;
        bool isValidUser;
        uint256 pendingStaticRewards;
        uint256 pendingLevelRewards;
        uint256 lastUpdateTime;
        uint256 totalStaticEarned; // 累计获得的静态收益
        uint256 totalDeposited;    // 累计入金金额
    }
    
    LevelConfig[TOTAL_LEVELS] public levelConfigs;
    uint256[3] public generationRewardRates = [1000, 500, 200];
    uint256 public constant PEER_REWARD_RATE = 1000;
    
    mapping(address => UserInfo) public users;
    mapping(address => bool) public isRegistered;
    mapping(address => bool) public authorizedCallers;
    
    uint256 public totalUsers;
    uint256 public totalValidUsers;
    IERC20 public rewardToken;
    IStakingPool public stakingPool;
    
    event ReferrerBound(address indexed user, address indexed referrer);
    event TeamPerformanceUpdated(address indexed user, int256 amountChange, uint256 newTotal, uint256 newSmall);
    event LevelUpgraded(address indexed user, uint256 oldLevel, uint256 newLevel);
    event StaticRewardDistributed(address indexed user, address[] receivers, uint256[] amounts, uint256[] generations);
    event LevelRewardClaimed(address indexed user, uint256 amount, uint256 level);
    event StaticRewardClaimed(address indexed user, uint256 amount);
    event AuthorizedCallerSet(address indexed caller, bool authorized);
    event UserStatusUpdated(address indexed user, bool isValid);
    
    modifier onlyAuthorized() {
        require(authorizedCallers[msg.sender] || msg.sender == owner(), "Not authorized");
        _;
    }
    
    modifier userExists(address user) {
        require(isRegistered[user], "User not registered");
        _;
    }
    
    constructor(address _rewardToken, address _stakingPool, address _initialOwner) Ownable(_initialOwner) {
        require(_rewardToken != address(0), "Invalid token address");
        require(_stakingPool != address(0), "Invalid staking pool address");
        
        rewardToken = IERC20(_rewardToken);
        stakingPool = IStakingPool(_stakingPool);
        _initializeLevelConfigs();
    }
    
    // --- 核心功能 1: 关系绑定 ---
    function bindReferrer(address referrerCode) external {
        require(!isRegistered[msg.sender], "Already registered");
        require(referrerCode != address(0), "Invalid referrer");
        require(referrerCode != msg.sender, "Cannot refer self");
        require(isRegistered[referrerCode], "Referrer not registered");
        
        _checkNoCycle(msg.sender, referrerCode);
        
        isRegistered[msg.sender] = true;
        users[msg.sender].referrer = referrerCode;
        users[msg.sender].lastUpdateTime = block.timestamp;
        users[msg.sender].level = 0;
        users[msg.sender].directReferrals = new address[](0);
        
        users[referrerCode].directReferrals.push(msg.sender);
        totalUsers++;
        
        emit ReferrerBound(msg.sender, referrerCode);
    }
    
    function _checkNoCycle(address newUser, address referrer) internal view {
        address current = referrer;
        while (current != address(0)) {
            require(current != newUser, "Cycle detected");
            current = users[current].referrer;
        }
    }
    
    // --- 核心功能 2: 数据存储与计算 ---
    function updateTeamPerformance(
        address user, 
        int256 amountChange, 
        bool isDeposit
    ) external onlyAuthorized userExists(user) {
        UserInfo storage userInfo = users[user];
        
        // 更新累计入金金额
        if (isDeposit && amountChange > 0) {
            userInfo.totalDeposited += uint256(amountChange);
        }
        
        // 更新有效用户状态
        _updateUserValidStatus(user);
        
        // 更新团队业绩
        if (amountChange > 0) {
            userInfo.totalTeamPerformance += uint256(amountChange);
        } else if (amountChange < 0) {
            uint256 change = uint256(-amountChange);
            if (change > userInfo.totalTeamPerformance) {
                userInfo.totalTeamPerformance = 0;
            } else {
                userInfo.totalTeamPerformance -= change;
            }
        }
        
        _updateUserLevel(user);
        _updateAncestorsPerformance(user, amountChange, isDeposit);
        
        emit TeamPerformanceUpdated(
            user, 
            amountChange, 
            userInfo.totalTeamPerformance, 
            userInfo.smallTeamPerformance
        );
    }
    
    function _updateUserValidStatus(address user) internal {
        UserInfo storage userInfo = users[user];
        bool wasValid = userInfo.isValidUser;
        
        // 检查是否达到有效用户门槛
        if (userInfo.totalDeposited >= MIN_VALID_USER_AMOUNT) {
            if (!userInfo.isValidUser) {
                userInfo.isValidUser = true;
                totalValidUsers++;
                emit UserStatusUpdated(user, true);
            }
        } else {
            if (userInfo.isValidUser) {
                userInfo.isValidUser = false;
                if (totalValidUsers > 0) totalValidUsers--;
                emit UserStatusUpdated(user, false);
            }
        }
    }
    
    function _updateAncestorsPerformance(
        address user, 
        int256 amountChange, 
        bool isDeposit
    ) internal {
        address currentReferrer = users[user].referrer;
        uint256 depth = 0;
        
        while (currentReferrer != address(0) && depth < MAX_GENERATION) {
            UserInfo storage referrerInfo = users[currentReferrer];
            
            if (amountChange > 0) {
                referrerInfo.totalTeamPerformance += uint256(amountChange);
            } else if (amountChange < 0) {
                uint256 change = uint256(-amountChange);
                if (change > referrerInfo.totalTeamPerformance) {
                    referrerInfo.totalTeamPerformance = 0;
                } else {
                    referrerInfo.totalTeamPerformance -= change;
                }
            }
            
            if (isDeposit) {
                _updateSmallTeamPerformance(currentReferrer, user, uint256(amountChange), amountChange > 0);
            }
            
            _updateUserLevel(currentReferrer);
            currentReferrer = referrerInfo.referrer;
            depth++;
        }
    }
    
    function _updateSmallTeamPerformance(
        address referrer, 
        address updatedChild,
        uint256 amount,
        bool isIncrease
    ) internal {
        UserInfo storage referrerInfo = users[referrer];
        address[] memory children = referrerInfo.directReferrals;
        
        if (children.length <= 1) {
            if (isIncrease) {
                referrerInfo.smallTeamPerformance += amount;
            } else {
                if (amount > referrerInfo.smallTeamPerformance) {
                    referrerInfo.smallTeamPerformance = 0;
                } else {
                    referrerInfo.smallTeamPerformance -= amount;
                }
            }
            return;
        }
        
        uint256 maxPerformance = 0;
        address maxChild = address(0);
        
        for (uint256 i = 0; i < children.length; i++) {
            address child = children[i];
            uint256 childPerf = users[child].totalTeamPerformance;
            
            if (child == updatedChild) {
                if (isIncrease) {
                    childPerf += amount;
                } else {
                    childPerf = childPerf > amount ? childPerf - amount : 0;
                }
            }
            
            if (childPerf > maxPerformance) {
                maxPerformance = childPerf;
                maxChild = child;
            }
        }
        
        uint256 newSmallTeamPerformance = 0;
        for (uint256 i = 0; i < children.length; i++) {
            address child = children[i];
            if (child != maxChild) {
                uint256 childPerf = users[child].totalTeamPerformance;
                if (child == updatedChild) {
                    if (isIncrease) {
                        childPerf += amount;
                    } else {
                        childPerf = childPerf > amount ? childPerf - amount : 0;
                    }
                }
                newSmallTeamPerformance += childPerf;
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
        
        for (uint256 i = 0; i < MAX_GENERATION; i++) {
            current = users[current].referrer;
            if (current == address(0)) break;
            
            if (!users[current].isValidUser) continue;
            
            uint256 reward = (rewardAmount * generationRewardRates[i]) / 10000;
            if (reward > 0) {
                users[current].pendingStaticRewards += reward;
                users[current].totalStaticEarned += reward; // 记录累计收益
                
                receivers[distributedCount] = current;
                amounts[distributedCount] = reward;
                generations[distributedCount] = i + 1;
                distributedCount++;
                totalDistributed += reward;
            }
        }
        
        if (distributedCount > 0) {
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
    
    // --- 核心功能 4: 动态收益等级奖 (迭代版本) ---
    function claimLevelReward(address user) external nonReentrant userExists(user) returns (uint256) {
        UserInfo storage userInfo = users[user];
        require(userInfo.level > 0, "No level");
        
        uint256 userRewardRate = levelConfigs[userInfo.level - 1].rewardRate;
        uint256 totalReward = 0;
        
        // 迭代计算伞下收益
        totalReward = _calculateLevelRewardIterative(user, userRewardRate);
        
        require(totalReward > 0, "No level reward to claim");
        
        userInfo.pendingLevelRewards += totalReward;
        uint256 toTransfer = userInfo.pendingLevelRewards;
        
        require(rewardToken.transfer(user, toTransfer), "Transfer failed");
        userInfo.pendingLevelRewards = 0;
        
        emit LevelRewardClaimed(user, toTransfer, userInfo.level);
        return toTransfer;
    }
    
    function _calculateLevelRewardIterative(address user, uint256 userRewardRate) internal view returns (uint256) {
        uint256 totalReward = 0;
        
        // 使用栈进行迭代遍历
        address[] memory stack = new address[](256);
        uint256 stackPointer = 0;
        
        // 初始化栈：将直推用户入栈
        UserInfo storage userInfo = users[user];
        for (uint256 i = 0; i < userInfo.directReferrals.length; i++) {
            if (stackPointer >= stack.length) {
                // 动态扩容
                address[] memory newStack = new address[](stack.length * 2);
                for (uint256 j = 0; j < stack.length; j++) {
                    newStack[j] = stack[j];
                }
                stack = newStack;
            }
            stack[stackPointer] = userInfo.directReferrals[i];
            stackPointer++;
        }
        
        // 处理栈中所有下级
        while (stackPointer > 0) {
            stackPointer--;
            address currentUser = stack[stackPointer];
            UserInfo storage childInfo = users[currentUser];
            
            // 计算下级收益
            uint256 childStaticRewards = childInfo.totalStaticEarned;
            
            if (childStaticRewards > 0) {
                if (childInfo.level < userInfo.level) {
                    uint256 childRewardRate = childInfo.level > 0 ? 
                        levelConfigs[childInfo.level - 1].rewardRate : 0;
                    uint256 rateDiff = userRewardRate - childRewardRate;
                    
                    if (rateDiff > 0) {
                        uint256 reward = (childStaticRewards * rateDiff) / 10000;
                        totalReward += reward;
                    }
                } else if (childInfo.level == userInfo.level) {
                    uint256 reward = (childStaticRewards * PEER_REWARD_RATE) / 10000;
                    totalReward += reward;
                }
            }
            
            // 将下级的下级入栈
            for (uint256 i = 0; i < childInfo.directReferrals.length; i++) {
                if (stackPointer >= stack.length) {
                    address[] memory newStack = new address[](stack.length * 2);
                    for (uint256 j = 0; j < stack.length; j++) {
                        newStack[j] = stack[j];
                    }
                    stack = newStack;
                }
                stack[stackPointer] = childInfo.directReferrals[i];
                stackPointer++;
            }
        }
        
        return totalReward;
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
        levelConfigs[0] = LevelConfig(10000 * 10**18, 1000);
        levelConfigs[1] = LevelConfig(30000 * 10**18, 2000);
        levelConfigs[2] = LevelConfig(100000 * 10**18, 3000);
        levelConfigs[3] = LevelConfig(300000 * 10**18, 4000);
        levelConfigs[4] = LevelConfig(1000000 * 10**18, 5000);
        levelConfigs[5] = LevelConfig(3000000 * 10**18, 6000);
        levelConfigs[6] = LevelConfig(10000000 * 10**18, 7000);
        levelConfigs[7] = LevelConfig(30000000 * 10**18, 8000);
        levelConfigs[8] = LevelConfig(100000000 * 10**18, 9000);
    }
    
    function _updateUserLevel(address user) internal {
        UserInfo storage userInfo = users[user];
        uint256 newLevel = 0;
        
        for (uint256 i = TOTAL_LEVELS; i > 0; i--) {
            if (userInfo.smallTeamPerformance >= levelConfigs[i-1].teamPerformance) {
                newLevel = i;
                break;
            }
        }
        
        if (newLevel != userInfo.level) {
            uint256 oldLevel = userInfo.level;
            userInfo.level = newLevel;
            
            if (newLevel > oldLevel) {
                emit LevelUpgraded(user, oldLevel, newLevel);
            }
        }
    }
    
    // --- 管理功能 ---
    function onWithdrawClearContribution(address user) external onlyAuthorized {
        users[user].isValidUser = false;
        _updateUserValidStatus(user);
    }
    
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit AuthorizedCallerSet(caller, authorized);
    }
    
    function setRewardToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token");
        rewardToken = IERC20(token);
    }
    
    function setStakingPool(address _stakingPool) external onlyOwner {
        require(_stakingPool != address(0), "Invalid staking pool");
        stakingPool = IStakingPool(_stakingPool);
    }
    
    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }
    
    // --- 视图函数 ---
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
        uint256 requiredForNextLevel,
        bool isValidUser,
        uint256 totalStaticEarned
    ) {
        UserInfo storage userInfo = users[user];
        level = userInfo.level;
        smallTeamPerformance = userInfo.smallTeamPerformance;
        totalTeamPerformance = userInfo.totalTeamPerformance;
        
        uint256 nextLevelReq = 0;
        if (level < TOTAL_LEVELS) {
            nextLevelReq = levelConfigs[level].teamPerformance;
        }
        
        return (
            level,
            smallTeamPerformance,
            totalTeamPerformance,
            nextLevelReq,
            userInfo.isValidUser,
            userInfo.totalStaticEarned
        );
    }
    
    function getUserReferrals(address user) external view returns (address[] memory) {
        return users[user].directReferrals;
    }
    
    function isUserValid(address user) external view returns (bool) {
        return users[user].isValidUser;
    }
}