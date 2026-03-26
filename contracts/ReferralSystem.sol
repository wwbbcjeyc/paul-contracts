// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title 推荐系统合约
 * @dev 实现多层次营销的推荐关系管理
 */
contract ReferralSystem is Ownable {
    // 数据结构
    struct ReferralInfo {
        address referrer;           // 推荐人地址
        uint256 referralCount;      // 总推荐数量
        bool isActive;              // 是否活跃（已入金）
    }
    
    // 存储映射
    mapping(address => ReferralInfo) public referrerInfo;           // 用户推荐信息
    mapping(address => address[]) public referralsOf;              // 用户的直接推荐列表
    mapping(address => uint256) public activeReferralCount;         // 活跃推荐数量
    
    // 系统配置
    address[] public allUsers;                                      // 所有用户列表
    mapping(address => bool) public registeredUsers;                // 已注册用户映射
    
    // 代数奖励比例 (基于1e18的精度)
    uint256[3] public referralRates = [1000, 500, 200];            // 10%, 5%, 2%
    uint256 public constant RATE_PRECISION = 10000;               // 100% = 10000
    
    // 事件
    event ReferralBound(address indexed user, address indexed referrer);
    event UserActivated(address indexed user);
    event ReferralRewardPaid(address indexed user, address indexed receiver, uint256 generation, uint256 amount);
    event EmergencyWithdraw(address token, uint256 amount);
    
    /**
     * @dev 构造函数
     */
    constructor() Ownable(msg.sender) {}
    
    /**
     * @dev 通过邀请码绑定推荐关系
     * @param _referrer 推荐人地址
     */
    function bindReferrer(address _referrer) external {
        address user = msg.sender;
        
        // 验证条件
        require(!registeredUsers[user], "User already registered");
        require(user != _referrer, "Cannot refer yourself");
        
        // 如果推荐人已注册，验证循环推荐
        if (registeredUsers[_referrer]) {
            require(!_isCircularReference(user, _referrer), "Circular reference detected");
        }
        
        // 记录推荐关系
        referrerInfo[user] = ReferralInfo({
            referrer: _referrer,
            referralCount: 0,
            isActive: false
        });
        
        // 如果推荐人已注册，添加到推荐列表
        if (registeredUsers[_referrer]) {
            referralsOf[_referrer].push(user);
            referrerInfo[_referrer].referralCount++;
        }
        
        // 注册用户
        registeredUsers[user] = true;
        allUsers.push(user);
        
        emit ReferralBound(user, _referrer);
    }
    
    /**
     * @dev 激活用户（模拟入金操作）
     * @param _user 要激活的用户地址
     */
    function activateUser(address _user) external onlyOwner {
        require(registeredUsers[_user], "User not registered");
        require(!referrerInfo[_user].isActive, "User already active");
        
        // 激活用户
        referrerInfo[_user].isActive = true;
        
        // 向上更新活跃推荐计数
        _updateActiveCount(_user);
        
        emit UserActivated(_user);
    }
    
    /**
     * @dev 获取用户的完整推荐链（包含空位紧缩）
     * @param _user 目标用户
     * @param _maxGenerations 最大代数
     * @return 有效的推荐地址数组
     */
    function getReferralChain(address _user, uint256 _maxGenerations) 
        public 
        view 
        returns (address[] memory) 
    {
        address[] memory chain = new address[](_maxGenerations);
        uint256 count = 0;
        address current = _user;
        
        for (uint256 i = 0; i < _maxGenerations; i++) {
            address referrer = referrerInfo[current].referrer;
            
            // 到达根节点或未注册
            if (referrer == address(0) || !registeredUsers[referrer]) {
                break;
            }
            
            // 紧缩机制：跳过非活跃推荐人
            if (!referrerInfo[referrer].isActive) {
                current = referrer;
                continue;
            }
            
            chain[count] = referrer;
            count++;
            current = referrer;
        }
        
        // 紧缩数组
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = chain[i];
        }
        
        return result;
    }
    
    /**
     * @dev 计算推荐奖励
     * @param _amount 总奖励金额
     * @param _user 目标用户
     * @return receivers 接收者数组
     * @return amounts 奖励金额数组
     * @return generations 对应代数数组
     */
    function calculateReferralRewards(uint256 _amount, address _user)
        public
        view
        returns (
            address[] memory receivers,
            uint256[] memory amounts,
            uint256[] memory generations
        )
    {
        // 获取推荐链
        address[] memory chain = getReferralChain(_user, referralRates.length);
        uint256 validCount = chain.length;
        
        receivers = new address[](validCount);
        amounts = new uint256[](validCount);
        generations = new uint256[](validCount);
        
        for (uint256 i = 0; i < validCount; i++) {
            receivers[i] = chain[i];
            generations[i] = i + 1; // 从第1代开始
            amounts[i] = (_amount * referralRates[i]) / RATE_PRECISION;
        }
    }
    
    /**
     * @dev 发放推荐奖励
     * @param _token 代币地址
     * @param _user 目标用户
     * @param _totalAmount 总奖励金额
     */
    function distributeRewards(address _token, address _user, uint256 _totalAmount) external onlyOwner {
        require(_totalAmount > 0, "Invalid amount");
        
        (
            address[] memory receivers,
            uint256[] memory amounts,
            uint256[] memory generations
        ) = calculateReferralRewards(_totalAmount, _user);
        
        IERC20 token = IERC20(_token);
        
        for (uint256 i = 0; i < receivers.length; i++) {
            if (receivers[i] != address(0) && amounts[i] > 0) {
                require(
                    token.transferFrom(msg.sender, receivers[i], amounts[i]),
                    "Transfer failed"
                );
                
                emit ReferralRewardPaid(_user, receivers[i], generations[i], amounts[i]);
            }
        }
    }
    
    /**
     * @dev 获取用户的直接推荐列表
     * @param _user 目标用户
     * @return 直接推荐地址数组
     */
    function getDirectReferrals(address _user) external view returns (address[] memory) {
        return referralsOf[_user];
    }
    
    /**
     * @dev 获取用户的活跃推荐列表
     * @param _user 目标用户
     * @return 活跃推荐地址数组
     */
    function getActiveReferrals(address _user) external view returns (address[] memory) {
        address[] memory allReferrals = referralsOf[_user];
        uint256 activeCount = 0;
        
        // 计算活跃数量
        for (uint256 i = 0; i < allReferrals.length; i++) {
            if (referrerInfo[allReferrals[i]].isActive) {
                activeCount++;
            }
        }
        
        // 构建结果数组
        address[] memory activeReferrals = new address[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allReferrals.length; i++) {
            if (referrerInfo[allReferrals[i]].isActive) {
                activeReferrals[index] = allReferrals[i];
                index++;
            }
        }
        
        return activeReferrals;
    }
    
    /**
     * @dev 检查循环推荐
     * @param _user 新用户
     * @param _referrer 推荐人
     * @return 是否存在循环推荐
     */
    function _isCircularReference(address _user, address _referrer) private view returns (bool) {
        address current = _referrer;
        
        while (current != address(0) && registeredUsers[current]) {
            if (current == _user) {
                return true;
            }
            current = referrerInfo[current].referrer;
        }
        
        return false;
    }
    
    /**
     * @dev 向上更新活跃推荐计数
     * @param _user 新激活的用户
     */
    function _updateActiveCount(address _user) private {
        address current = referrerInfo[_user].referrer;
        uint256 depth = 0;
        
        while (
            current != address(0) && 
            registeredUsers[current] && 
            depth < 100 // 防止无限循环的安全限制
        ) {
            if (referrerInfo[current].isActive) {
                activeReferralCount[current]++;
                break; // 只更新到第一个活跃上级
            }
            
            current = referrerInfo[current].referrer;
            depth++;
        }
    }
    
    /**
     * @dev 紧急提取代币
     * @param _token 代币地址
     */
    function emergencyWithdraw(address _token) external onlyOwner {
        IERC20 token = IERC20(_token);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "No balance");
        
        require(token.transfer(owner(), balance), "Transfer failed");
        emit EmergencyWithdraw(_token, balance);
    }
    
    /**
     * @dev 更新代数奖励比例
     * @param _rates 新的奖励比例数组
     */
    function updateReferralRates(uint256[3] calldata _rates) external onlyOwner {
        require(_rates.length == 3, "Invalid rates length");
        
        // 验证总和不超过100%
        uint256 total = 0;
        for (uint256 i = 0; i < _rates.length; i++) {
            total += _rates[i];
        }
        require(total <= RATE_PRECISION, "Total rate exceeds 100%");
        
        referralRates = _rates;
    }
    
    /**
     * @dev 获取用户总数
     */
    function getTotalUsers() external view returns (uint256) {
        return allUsers.length;
    }
}