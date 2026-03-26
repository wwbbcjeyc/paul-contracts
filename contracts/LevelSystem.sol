// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title 等级与级差奖励系统
 * @dev 实现9级等级制度和级差奖励算法
 */
contract LevelSystem is Ownable {
    // 等级定义
    enum Level {
        L0,  // 未激活
        L1,  // 10,000U
        L2,  // 30,000U
        L3,  // 100,000U
        L4,  // 300,000U
        L5,  // 1,000,000U
        L6,  // 3,000,000U
        L7,  // 10,000,000U
        L8,  // 30,000,000U
        L9   // 100,000,000U
    }
    
    // 等级标准（单位：USD，精度1e6）
    uint256[10] public levelThresholds = [
        0,          // L0
        10_000e6,   // L1: 10,000U
        30_000e6,   // L2: 30,000U
        100_000e6,  // L3: 100,000U
        300_000e6,  // L4: 300,000U
        1_000_000e6,// L5: 1,000,000U
        3_000_000e6,// L6: 3,000,000U
        10_000_000e6,// L7: 10,000,000U
        30_000_000e6,// L8: 30,000,000U
        100_000_000e6 // L9: 100,000,000U
    ];
    
    // 等级奖励比例（基于1e6精度）
    uint256[10] public levelRates = [
        0,   // L0: 0%
        5e4, // L1: 5%
        7e4, // L2: 7%
        10e4,// L3: 10%
        12e4,// L4: 12%
        15e4,// L5: 15%
        18e4,// L6: 18%
        20e4,// L7: 20%
        22e4,// L8: 22%
        25e4 // L9: 25%
    ];
    
    // 平级奖励比例
    uint256 public constant PEER_RATE = 1e4; // 1% 平级奖励
    
    // 精度常量
    uint256 public constant RATE_PRECISION = 1e6;
    
    // 用户数据结构
    struct UserInfo {
        Level level;                // 当前等级
        Level pendingLevel;         // 待确认等级
        uint256 directAmount;       // 直推业绩
        uint256 teamAmount;         // 团队总业绩
        uint256 smallAreaAmount;    // 小区业绩
        uint256 maxSmallArea;       // 最大小区业绩
        uint256 totalRewards;       // 累计奖励
        uint256 claimedRewards;     // 已领取奖励
        bool activated;            // 是否已激活
        uint256 lastUpdate;         // 最后更新时间戳
    }
    
    // 推荐关系
    struct ReferralInfo {
        address referrer;          // 推荐人
        address[] referrals;       // 直推列表
        mapping(address => uint256) referralIndex; // 直推索引
    }
    
    // 存储映射
    mapping(address => UserInfo) public userInfo;
    mapping(address => ReferralInfo) public referralInfo;
    
    // 活跃用户列表
    address[] public activeUsers;
    mapping(address => uint256) public userIndex;
    
    // 烧伤记录
    struct BurnRecord {
        uint256 amount;            // 已烧伤金额
        uint256 timestamp;         // 烧伤时间
    }
    
    mapping(address => BurnRecord[]) public burnRecords; // 烧伤记录
    mapping(address => uint256) public totalBurned;      // 总烧伤金额
    
    // 事件
    event UserActivated(address indexed user, address indexed referrer);
    event LevelUpdated(address indexed user, Level oldLevel, Level newLevel);
    event PerformanceAdded(address indexed user, uint256 amount, uint256 directAmount, uint256 teamAmount);
    event LevelRewardDistributed(address indexed from, address indexed to, uint256 levelDiff, uint256 amount);
    event PeerRewardDistributed(address indexed from, address indexed to, uint256 amount);
    event Burned(address indexed user, uint256 amount, uint256 burnRate);
    event RewardClaimed(address indexed user, uint256 amount);
    
    /**
     * @dev 构造函数
     */
    constructor() Ownable(msg.sender) {}
    
    /**
     * @dev 激活用户
     * @param _user 用户地址
     * @param _referrer 推荐人地址
     */
    function activateUser(address _user, address _referrer) external onlyOwner {
        require(_user != address(0), "Invalid user");
        require(!userInfo[_user].activated, "Already activated");
        require(_user != _referrer, "Cannot refer yourself");
        
        // 设置推荐关系
        if (_referrer != address(0) && userInfo[_referrer].activated) {
            _setReferrer(_user, _referrer);
        }
        
        // 初始化用户信息
        userInfo[_user] = UserInfo({
            level: Level.L0,
            pendingLevel: Level.L0,
            directAmount: 0,
            teamAmount: 0,
            smallAreaAmount: 0,
            maxSmallArea: 0,
            totalRewards: 0,
            claimedRewards: 0,
            activated: true,
            lastUpdate: block.timestamp
        });
        
        // 添加到活跃列表
        activeUsers.push(_user);
        userIndex[_user] = activeUsers.length - 1;
        
        emit UserActivated(_user, _referrer);
    }
    
    /**
     * @dev 添加业绩
     * @param _user 用户地址
     * @param _amount 业绩金额
     */
    function addPerformance(address _user, uint256 _amount) external onlyOwner {
        require(userInfo[_user].activated, "User not activated");
        require(_amount > 0, "Invalid amount");
        
        // 更新用户业绩
        _updateUserPerformance(_user, _amount);
        
        // 更新上级团队业绩
        _updateUpstreamPerformance(_user, _amount);
        
        // 检查等级更新
        _checkLevelUpdate(_user);
        
        emit PerformanceAdded(_user, _amount, userInfo[_user].directAmount, userInfo[_user].teamAmount);
    }
    
    /**
     * @dev 计算级差奖励
     * @param _user 业绩贡献者
     * @param _amount 业绩金额
     * @return receivers 接收奖励的地址列表
     * @return amounts 对应每个接收者的奖励金额列表
     * @return levelDiffs 等级差值列表（0表示平级奖励，正值表示级差奖励）
     */
    function calculateLevelRewards(address _user, uint256 _amount) 
        public  
        returns (
            address[] memory receivers,
            uint256[] memory amounts,
            uint256[] memory levelDiffs
        ) 
    {
        address[] memory tempReceivers = new address[](10);
        uint256[] memory tempAmounts = new uint256[](10);
        uint256[] memory tempDiffs = new uint256[](10);
        
        uint256 count = 0;
        address current = userInfo[_user].activated ? referralInfo[_user].referrer : address(0);
        uint256 lastRate = 0;
        
        // 烧伤机制：记录每个等级已烧伤的金额
        mapping(address => uint256) storage burned = totalBurned;
        
        while (current != address(0) && count < 10) {
            uint256 currentRate = uint256(levelRates[uint256(userInfo[current].level)]);
            
            if (currentRate > lastRate) {
                uint256 rateDiff = currentRate - lastRate;
                uint256 rewardAmount = (_amount * rateDiff) / RATE_PRECISION;
                
                // 应用烧伤机制
                uint256 burnedAmount = burned[current];
                if (burnedAmount > 0) {
                    uint256 availableAmount = rewardAmount;
                    if (burnedAmount >= rewardAmount) {
                        availableAmount = 0;
                        burned[current] -= rewardAmount;
                    } else {
                        availableAmount = rewardAmount - burnedAmount;
                        burned[current] = 0;
                    }
                    
                    if (availableAmount > 0) {
                        tempReceivers[count] = current;
                        tempAmounts[count] = availableAmount;
                        tempDiffs[count] = rateDiff;
                        count++;
                    }
                } else {
                    tempReceivers[count] = current;
                    tempAmounts[count] = rewardAmount;
                    tempDiffs[count] = rateDiff;
                    count++;
                }
                
                lastRate = currentRate;
            } else if (currentRate == lastRate) {
                // 平级奖励
                uint256 peerReward = (_amount * PEER_RATE) / RATE_PRECISION;
                tempReceivers[count] = current;
                tempAmounts[count] = peerReward;
                tempDiffs[count] = 0; // 0表示平级奖励
                count++;
            }
            
            // 烧伤记录：将奖励金额记录下来用于下级烧伤
            burned[current] += (_amount * currentRate) / RATE_PRECISION;
            
            current = userInfo[current].activated ? referralInfo[current].referrer : address(0);
        }
        
        // 构建结果数组
        receivers = new address[](count);
        amounts = new uint256[](count);
        levelDiffs = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            receivers[i] = tempReceivers[i];
            amounts[i] = tempAmounts[i];
            levelDiffs[i] = tempDiffs[i];
        }
    }
    
    /**
     * @dev 分发级差奖励
     * @param _user 业绩贡献者
     * @param _amount 业绩金额
     * @param _token 奖励代币
     */
    function distributeLevelRewards(address _user, uint256 _amount, address _token) external onlyOwner {
        require(_amount > 0, "Invalid amount");
        
        (
            address[] memory receivers,
            uint256[] memory amounts,
            uint256[] memory levelDiffs
        ) = calculateLevelRewards(_user, _amount);
        
        IERC20 token = IERC20(_token);
        
        for (uint256 i = 0; i < receivers.length; i++) {
            if (receivers[i] != address(0) && amounts[i] > 0) {
                // 发放奖励
                require(
                    token.transferFrom(msg.sender, receivers[i], amounts[i]),
                    "Transfer failed"
                );
                
                // 更新用户奖励记录
                userInfo[receivers[i]].totalRewards += amounts[i];
                
                if (levelDiffs[i] > 0) {
                    // 级差奖励
                    emit LevelRewardDistributed(_user, receivers[i], levelDiffs[i], amounts[i]);
                } else {
                    // 平级奖励
                    emit PeerRewardDistributed(_user, receivers[i], amounts[i]);
                }
            }
        }
        
        // 记录烧伤
        _recordBurns(_user, receivers, amounts);
    }
    
    /**
     * @dev 领取奖励
     * @param _user 用户地址
     */
    function claimRewards(address _user) external {
        require(msg.sender == _user || msg.sender == owner(), "Unauthorized");
        
        UserInfo storage user = userInfo[_user];
        uint256 claimable = user.totalRewards - user.claimedRewards;
        
        require(claimable > 0, "No rewards to claim");
        
        user.claimedRewards += claimable;
        
        emit RewardClaimed(_user, claimable);
    }
    
    /**
     * @dev 获取用户等级
     * @param _user 用户地址
     */
    function getUserLevel(address _user) external view returns (Level) {
        return userInfo[_user].level;
    }
    
    /**
     * @dev 获取用户业绩统计
     */
    function getUserPerformance(address _user) external view returns (
        uint256 directAmount,
        uint256 teamAmount,
        uint256 smallAreaAmount
    ) {
        UserInfo storage user = userInfo[_user];
        return (user.directAmount, user.teamAmount, user.smallAreaAmount);
    }
    
    /**
     * @dev 获取用户的推荐网络
     */
    function getReferralNetwork(address _user, uint256 _depth) external view returns (
        address[] memory network,
        uint256[] memory levels
    ) {
        address[] memory tempNetwork = new address[](_depth);
        uint256[] memory tempLevels = new uint256[](_depth);
        
        uint256 count = 0;
        address current = _user;
        
        for (uint256 i = 0; i < _depth; i++) {
            if (!userInfo[current].activated) break;
            
            address[] storage refs = referralInfo[current].referrals;
            for (uint256 j = 0; j < refs.length; j++) {
                if (count >= _depth) break;
                
                tempNetwork[count] = refs[j];
                tempLevels[count] = uint256(userInfo[refs[j]].level);
                count++;
            }
            
            if (count >= _depth) break;
        }
        
        // 紧缩数组
        network = new address[](count);
        levels = new uint256[](count);
        
        for (uint256 i = 0; i < count; i++) {
            network[i] = tempNetwork[i];
            levels[i] = tempLevels[i];
        }
    }
    
    // ========== 内部函数 ==========
    
    /**
     * @dev 设置推荐关系
     */
    function _setReferrer(address _user, address _referrer) private {
        referralInfo[_user].referrer = _referrer;
        referralInfo[_referrer].referrals.push(_user);
        referralInfo[_referrer].referralIndex[_user] = referralInfo[_referrer].referrals.length - 1;
    }
    
    /**
     * @dev 更新用户业绩
     */
    function _updateUserPerformance(address _user, uint256 _amount) private {
        UserInfo storage user = userInfo[_user];
        
        // 更新团队业绩
        user.teamAmount += _amount;
        
        // 更新上级的直推业绩
        address referrer = referralInfo[_user].referrer;
        if (referrer != address(0) && userInfo[referrer].activated) {
            userInfo[referrer].directAmount += _amount;
            
            // 更新上级的小区业绩
            _updateSmallAreaPerformance(referrer, _amount);
        }
    }
    
    /**
     * @dev 更新上级业绩
     */
    function _updateUpstreamPerformance(address _user, uint256 _amount) private {
        address current = referralInfo[_user].referrer;
        
        while (current != address(0) && userInfo[current].activated) {
            // 更新团队总业绩
            userInfo[current].teamAmount += _amount;
            
            // 检查等级更新
            _checkLevelUpdate(current);
            
            current = referralInfo[current].referrer;
        }
    }
    
    /**
     * @dev 更新小区业绩
     */
    function _updateSmallAreaPerformance(address _referrer, uint256 _amount) private {
        UserInfo storage referrer = userInfo[_referrer];
        
        // 找到这个直推在小区中的贡献
        referrer.smallAreaAmount += _amount;
        
        // 更新最大小区
        if (_amount > referrer.maxSmallArea) {
            referrer.maxSmallArea = _amount;
        }
        
        // 自动回滚：如果小区业绩超过阈值，触发等级重算
        if (referrer.smallAreaAmount >= levelThresholds[uint256(referrer.level) + 1]) {
            referrer.pendingLevel = Level(uint256(referrer.level) + 1);
        }
    }
    
    /**
     * @dev 检查并更新等级
     */
    function _checkLevelUpdate(address _user) private {
        UserInfo storage user = userInfo[_user];
        Level currentLevel = user.level;
        Level newLevel = _calculateLevel(_user);
        
        if (newLevel > currentLevel) {
            user.pendingLevel = newLevel;
        } else if (newLevel < currentLevel) {
            // 等级回滚逻辑
            if (user.teamAmount < levelThresholds[uint256(currentLevel)]) {
                user.pendingLevel = _calculateLevelBasedOnPerformance(user.teamAmount);
            }
        }
    }
    
    /**
     * @dev 根据业绩计算等级
     */
    function _calculateLevel(address _user) private view returns (Level) {
        UserInfo storage user = userInfo[_user];
        uint256 teamPerformance = user.teamAmount;
        
        for (uint256 i = 9; i >= 1; i--) {
            if (teamPerformance >= levelThresholds[i]) {
                return Level(i);
            }
        }
        
        return Level.L0;
    }
    
    /**
     * @dev 根据业绩数值计算等级
     */
    function _calculateLevelBasedOnPerformance(uint256 _performance) private view returns (Level) {
        for (uint256 i = 9; i >= 1; i--) {
            if (_performance >= levelThresholds[i]) {
                return Level(i);
            }
        }
        
        return Level.L0;
    }
    
    /**
     * @dev 确认等级更新
     */
    function _confirmLevelUpdate(address _user) private {
        UserInfo storage user = userInfo[_user];
        if (user.pendingLevel > user.level) {
            Level oldLevel = user.level;
            user.level = user.pendingLevel;
            emit LevelUpdated(_user, oldLevel, user.pendingLevel);
        }
    }
    
    /**
     * @dev 记录烧伤
     */
    function _recordBurns(address _user, address[] memory _receivers, uint256[] memory _amounts) private {
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < _receivers.length; i++) {
            totalDistributed += _amounts[i];
        }
        
        // 记录烧伤金额
        burnRecords[_user].push(BurnRecord({
            amount: totalDistributed,
            timestamp: block.timestamp
        }));
        
        totalBurned[_user] += totalDistributed;
        
        emit Burned(_user, totalDistributed, 0);
    }
    
    // ========== 管理函数 ==========
    
    /**
     * @dev 手动更新等级
     */
    function updateLevel(address _user) external onlyOwner {
        _confirmLevelUpdate(_user);
    }
    
    /**
     * @dev 批量更新等级
     */
    function batchUpdateLevel(address[] calldata _users) external onlyOwner {
        for (uint256 i = 0; i < _users.length; i++) {
            _confirmLevelUpdate(_users[i]);
        }
    }
    
    /**
     * @dev 获取烧伤记录
     */
    function getBurnRecords(address _user) external view returns (BurnRecord[] memory) {
        return burnRecords[_user];
    }
    
    /**
     * @dev 获取活跃用户数量
     */
    function getActiveUserCount() external view returns (uint256) {
        return activeUsers.length;
    }
}