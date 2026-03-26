// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title CorePool
 * @dev 核心资金池合约 - 包含入金、撤资、分红功能
 */
contract CorePool is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    
    // ==================== 常量定义 ====================
    uint256 public constant MIN_DEPOSIT = 100 * 1e6;
    uint256 public constant DEPOSIT_MULTIPLE = 100 * 1e6;
    uint256 public constant MAX_INDIVIDUAL_DEPOSIT = 50000 * 1e6;
    uint256 public constant WITHDRAW_DELAY = 24 hours;
    uint256 public constant DIVIDEND_CLAIM_WINDOW = 24 hours;
    
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant PAUL_PURCHASE_RATE = 3000;
    uint256 private constant PRINCIPAL_RATE = 7000;
    
    uint256 private constant BASE_MULTIPLIER = 10000;
    uint256 private constant TIER1_MULTIPLIER = 12000;
    uint256 private constant TIER2_MULTIPLIER = 15000;
    uint256 private constant TIER1_THRESHOLD = 3000 * 1e6;
    uint256 private constant TIER2_THRESHOLD = 10000 * 1e6;
    
    // ==================== 状态变量 ====================
    struct UserInfo {
        uint256 totalDeposit;
        uint256 principalBalance;
        uint256 contribution;
        uint256 lastDepositTime;
        address referrer;
        uint8 level;
        uint256 teamPerformance;
        bool isActive;
        uint256 lastDividendClaim;
        uint256 claimedDividends;
    }
    
    struct DepositRecord {
        uint256 amount;
        uint256 time;
        uint256 contributionGained;
        bool isActive;
    }
    
    struct DividendPool {
        uint256 totalAmount;
        uint256 distributionTime;
        uint256 totalContributions;
        uint256 claimedAmount;
    }
    
    mapping(address => UserInfo) public userInfo;
    mapping(address => DepositRecord[]) public depositRecords;
    mapping(address => mapping(uint256 => bool)) public dividendClaims; // 分红领取记录
    mapping(uint256 => DividendPool) public dividendPools; // 轮次分红池
    
    IERC20 public usdtToken;
    IERC20 public paulToken;
    
    uint256 public totalDeposits;
    uint256 public totalContributions;
    uint256 public currentDividendRound;
    address public owner;
    
    // ==================== 事件定义 ====================
    event Deposited(address indexed user, uint256 amount, uint256 contribution);
    event Withdrawn(address indexed user, uint256 amount);
    event ContributionUpdated(address indexed user, uint256 newContribution);
    event DividendDistributed(uint256 round, uint256 totalAmount, uint256 distributionTime);
    event DividendClaimed(address indexed user, uint256 round, uint256 amount);
    event DividendExpired(uint256 round, uint256 expiredAmount);
    event TeamPerformanceRolledBack(address indexed user, uint256 amount);
    event PaulPurchaseRecorded(address indexed user, uint256 amount);
    
    // ==================== 构造函数 ====================
    constructor(address _usdtToken, address _paulToken) {
        usdtToken = IERC20(_usdtToken);
        paulToken = IERC20(_paulToken);
        owner = msg.sender;
    }
    
    // ==================== 修饰器 ====================
    modifier onlyOwner() {
        require(msg.sender == owner, "CorePool: caller is not owner");
        _;
    }
    
    // ==================== 入金功能 ====================
    
    /**
     * @dev 存款函数
     * @param amount 存款金额
     * @param referrer 推荐人地址
     */
    function deposit(uint256 amount, address referrer) external nonReentrant {
        address user = msg.sender;
        
        // 参数验证
        _validateDepositAmount(amount);
        
        // 检查单账号累计上限
        UserInfo memory userData = userInfo[user];
        uint256 newTotal = userData.totalDeposit.add(amount);
        require(
            newTotal <= MAX_INDIVIDUAL_DEPOSIT,
            "CorePool: individual deposit limit exceeded"
        );
        
        // 首次存款绑定推荐人
        if (userData.totalDeposit == 0 && referrer != address(0) && referrer != user) {
            _setReferrer(user, referrer);
        }
        
        // 转账
        usdtToken.safeTransferFrom(user, address(this), amount);
        
        // 计算金额拆分
        (uint256 paulAmount, uint256 principalAmount) = _calculateSplitAmounts(amount);
        
        // 计算贡献值
        uint256 contribution = _calculateContribution(amount);
        
        // 更新用户信息
        _updateUserInfo(user, amount, principalAmount, contribution, referrer);
        
        // 记录存款记录
        _addDepositRecord(user, amount, contribution);
        
        // 更新全局统计
        totalDeposits = totalDeposits.add(amount);
        totalContributions = totalContributions.add(contribution);
        
        // 更新团队业绩
        _updateTeamPerformance(user, amount);
        
        // 记录PAUL购买
        _recordPaulPurchase(user, paulAmount);
        
        // 触发事件
        emit Deposited(user, amount, contribution);
    }
    
    // ==================== 撤资功能 ====================
    
    /**
     * @dev 撤资函数
     */
    function withdraw() external nonReentrant {
        address user = msg.sender;
        UserInfo storage userData = userInfo[user];
        
        // 撤资条件检查
        _validateWithdrawalConditions(userData);
        
        // 计算可撤资金额
        uint256 withdrawAmount = userData.principalBalance;
        require(withdrawAmount > 0, "CorePool: no principal to withdraw");
        
        // 检查合约USDT余额
        uint256 contractBalance = usdtToken.balanceOf(address(this));
        require(contractBalance >= withdrawAmount, "CorePool: insufficient contract balance");
        
        // 转账给用户
        usdtToken.safeTransfer(user, withdrawAmount);
        
        // 记录分红回收
        uint256 expiredDividends = _handleExpiredDividends(user);
        
        // 保存贡献值用于更新全局统计
        uint256 userContribution = userData.contribution;
        
        // 更新用户状态
        userData.principalBalance = 0;
        userData.contribution = 0;
        userData.isActive = false;
        
        // 更新全局统计
        totalDeposits = totalDeposits.sub(withdrawAmount);
        totalContributions = totalContributions.sub(userContribution);
        
        // 回滚团队业绩
        _rollbackTeamPerformance(user, userData.totalDeposit);
        
        // 标记存款记录为无效
        _invalidateDepositRecords(user);
        
        // 触发事件
        emit Withdrawn(user, withdrawAmount);
        if (expiredDividends > 0) {
            emit DividendExpired(currentDividendRound, expiredDividends);
        }
    }
    
    /**
     * @dev 验证撤资条件
     * @param userData 用户信息
     */
    function _validateWithdrawalConditions(UserInfo memory userData) private view {
        require(userData.isActive, "CorePool: user not active");
        require(userData.principalBalance > 0, "CorePool: no principal balance");
        require(
            block.timestamp >= userData.lastDepositTime.add(WITHDRAW_DELAY),
            "CorePool: withdrawal time not reached"
        );
    }
    
    /**
     * @dev 回滚团队业绩
     * @param user 用户地址
     * @param amount 回滚金额
     */
    function _rollbackTeamPerformance(address user, uint256 amount) private {
        address referrer = userInfo[user].referrer;
        uint256 levelsRolled = 0;
        
        // 简单实现：只回滚直接上级
        while (referrer != address(0) && levelsRolled < 10) {
            if (userInfo[referrer].isActive) {
                userInfo[referrer].teamPerformance = userInfo[referrer].teamPerformance.sub(amount);
                emit TeamPerformanceRolledBack(referrer, amount);
            }
            
            referrer = userInfo[referrer].referrer;
            levelsRolled++;
        }
    }
    
    /**
     * @dev 标记存款记录为无效
     * @param user 用户地址
     */
    function _invalidateDepositRecords(address user) private {
        DepositRecord[] storage records = depositRecords[user];
        for (uint256 i = 0; i < records.length; i++) {
            if (records[i].isActive) {
                records[i].isActive = false;
            }
        }
    }
    
    // ==================== 分红奖励功能 ====================
    
    /**
     * @dev 分红分发函数（仅管理员可调用）
     * @param amount 分发金额
     */
    function distributeDividend(uint256 amount) external onlyOwner {
        require(amount > 0, "CorePool: dividend amount must be positive");
        require(totalContributions > 0, "CorePool: no contributions yet");
        
        // 转移代币到合约
        paulToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // 创建新的分红轮次
        currentDividendRound++;
        dividendPools[currentDividendRound] = DividendPool({
            totalAmount: amount,
            distributionTime: block.timestamp,
            totalContributions: totalContributions,
            claimedAmount: 0
        });
        
        emit DividendDistributed(currentDividendRound, amount, block.timestamp);
    }
    
    /**
     * @dev 领取分红
     */
    function claimDividend() external nonReentrant {
        address user = msg.sender;
        UserInfo storage userData = userInfo[user];
        
        require(userData.isActive, "CorePool: user not active");
        require(userData.contribution > 0, "CorePool: no contribution");
        
        uint256 round = currentDividendRound;
        require(round > 0, "CorePool: no dividend round");
        
        DividendPool storage pool = dividendPools[round];
        require(pool.totalAmount > 0, "CorePool: no dividend in this round");
        
        // 检查是否已领取
        require(!dividendClaims[user][round], "CorePool: already claimed");
        
        // 检查是否过期
        require(
            block.timestamp <= pool.distributionTime.add(DIVIDEND_CLAIM_WINDOW),
            "CorePool: claim window expired"
        );
        
        // 计算分红金额
        uint256 dividendAmount = _calculateDividend(user, round);
        require(dividendAmount > 0, "CorePool: no dividend to claim");
        
        // 检查池余额
        uint256 poolBalance = paulToken.balanceOf(address(this));
        require(poolBalance >= dividendAmount, "CorePool: insufficient pool balance");
        
        // 更新状态
        dividendClaims[user][round] = true;
        pool.claimedAmount = pool.claimedAmount.add(dividendAmount);
        userData.lastDividendClaim = block.timestamp;
        userData.claimedDividends = userData.claimedDividends.add(dividendAmount);
        
        // 分发代币
        paulToken.safeTransfer(user, dividendAmount);
        
        emit DividendClaimed(user, round, dividendAmount);
    }
    
    /**
     * @dev 计算分红金额
     * @param user 用户地址
     * @param round 分红轮次
     * @return 分红金额
     */
    function _calculateDividend(address user, uint256 round) private view returns (uint256) {
        UserInfo memory userData = userInfo[user];
        DividendPool memory pool = dividendPools[round];
        
        if (pool.totalContributions == 0 || userData.contribution == 0) {
            return 0;
        }
        
        // 计算比例：userShare = poolAmount * (userContribution / totalContributions)
        uint256 share = pool.totalAmount.mul(userData.contribution).div(pool.totalContributions);
        return share;
    }
    
    /**
     * @dev 处理过期分红
     * @param user 用户地址
     * @return 过期金额
     */
    function _handleExpiredDividends(address user) private returns (uint256) {
        uint256 expiredAmount = 0;
        
        // 检查当前轮次是否过期
        uint256 round = currentDividendRound;
        if (round == 0) return 0;
        
        DividendPool storage pool = dividendPools[round];
        if (pool.distributionTime == 0) return 0;
        
        if (block.timestamp > pool.distributionTime.add(DIVIDEND_CLAIM_WINDOW)) {
            // 计算用户未领取的分红
            if (!dividendClaims[user][round]) {
                uint256 userDividend = _calculateDividend(user, round);
                if (userDividend > 0) {
                    expiredAmount = userDividend;
                    dividendClaims[user][round] = true;
                    pool.claimedAmount = pool.claimedAmount.add(userDividend);
                }
            }
        }
        
        return expiredAmount;
    }
    
    /**
     * @dev 清理过期分红（仅管理员）
     */
    function cleanupExpiredDividends(uint256 round) external onlyOwner {
        DividendPool storage pool = dividendPools[round];
        require(pool.distributionTime > 0, "CorePool: pool not exists");
        require(
            block.timestamp > pool.distributionTime.add(DIVIDEND_CLAIM_WINDOW),
            "CorePool: claim window not expired"
        );
        
        // 计算未领取的过期分红
        uint256 unclaimedAmount = pool.totalAmount.sub(pool.claimedAmount);
        if (unclaimedAmount > 0) {
            // 可以转移回指定地址或保留在合约中
            paulToken.safeTransfer(owner, unclaimedAmount);
            pool.claimedAmount = pool.totalAmount;
        }
    }
    
    // ==================== 辅助函数 ====================
    
    function _validateDepositAmount(uint256 amount) private pure {
        require(amount >= MIN_DEPOSIT, "CorePool: amount below minimum");
        require(amount % DEPOSIT_MULTIPLE == 0, "CorePool: amount must be multiple of 100");
    }
    
    function _calculateSplitAmounts(uint256 amount) private pure returns (uint256, uint256) {
        uint256 paulAmount = amount.mul(PAUL_PURCHASE_RATE).div(BASIS_POINTS);
        uint256 principalAmount = amount.mul(PRINCIPAL_RATE).div(BASIS_POINTS);
        
        if (paulAmount.add(principalAmount) < amount) {
            principalAmount = amount.sub(paulAmount);
        }
        
        return (paulAmount, principalAmount);
    }
    
    function _calculateContribution(uint256 amount) private pure returns (uint256) {
        uint256 multiplier = BASE_MULTIPLIER;
        if (amount >= TIER2_THRESHOLD) {
            multiplier = TIER2_MULTIPLIER;
        } else if (amount >= TIER1_THRESHOLD) {
            multiplier = TIER1_MULTIPLIER;
        }
        
        return amount.mul(multiplier).div(BASIS_POINTS);
    }
    
    function _setReferrer(address user, address referrer) private {
        UserInfo storage userData = userInfo[user];
        require(userData.referrer == address(0), "CorePool: referrer already set");
        
        uint32 size;
        assembly {
            size := extcodesize(referrer)
        }
        require(size == 0, "CorePool: referrer cannot be contract");
        
        // 确保推荐人已存在
        require(
            userInfo[referrer].totalDeposit > 0 || referrer == address(0),
            "CorePool: referrer not registered"
        );
        
        userData.referrer = referrer;
    }
    
    function _updateUserInfo(
        address user,
        uint256 amount,
        uint256 principalAmount,
        uint256 contribution,
        address referrer
    ) private {
        UserInfo storage userData = userInfo[user];
        
        userData.totalDeposit = userData.totalDeposit.add(amount);
        userData.principalBalance = userData.principalBalance.add(principalAmount);
        userData.contribution = userData.contribution.add(contribution);
        userData.lastDepositTime = block.timestamp;
        userData.isActive = true;
        
        if (userData.referrer == address(0) && referrer != address(0)) {
            userData.referrer = referrer;
        }
        
        emit ContributionUpdated(user, userData.contribution);
    }
    
    function _addDepositRecord(
        address user,
        uint256 amount,
        uint256 contribution
    ) private {
        depositRecords[user].push(DepositRecord({
            amount: amount,
            time: block.timestamp,
            contributionGained: contribution,
            isActive: true
        }));
    }
    
    function _updateTeamPerformance(address user, uint256 amount) private {
        address referrer = userInfo[user].referrer;
        uint256 levelsUpdated = 0;
        
        while (referrer != address(0) && levelsUpdated < 10) {
            if (userInfo[referrer].isActive) {
                userInfo[referrer].teamPerformance = userInfo[referrer].teamPerformance.add(amount);
            }
            referrer = userInfo[referrer].referrer;
            levelsUpdated++;
        }
    }
    
    function _recordPaulPurchase(address user, uint256 amount) private {
        // 这里记录PAUL购买，实际购买逻辑可能需要单独实现
        // 可以记录到事件中或单独的数据结构中
        emit PaulPurchaseRecorded(user, amount);
    }
    
    // ==================== 查询函数 ====================
    
    /**
     * @dev 获取用户分红可领取金额
     * @param user 用户地址
     * @return 可领取金额
     */
    function getClaimableDividend(address user) external view returns (uint256) {
        uint256 round = currentDividendRound;
        if (round == 0) return 0;
        
        DividendPool memory pool = dividendPools[round];
        if (pool.distributionTime == 0) return 0;
        
        // 检查是否过期
        if (block.timestamp > pool.distributionTime.add(DIVIDEND_CLAIM_WINDOW)) {
            return 0;
        }
        
        // 检查是否已领取
        if (dividendClaims[user][round]) {
            return 0;
        }
        
        return _calculateDividend(user, round);
    }
    
    /**
     * @dev 获取用户待撤资金额
     * @param user 用户地址
     * @return 可撤资金额
     */
    function getWithdrawableAmount(address user) external view returns (uint256) {
        UserInfo memory userData = userInfo[user];
        
        if (!userData.isActive || 
            userData.principalBalance == 0 ||
            block.timestamp < userData.lastDepositTime.add(WITHDRAW_DELAY)) {
            return 0;
        }
        
        return userData.principalBalance;
    }
    
    /**
     * @dev 获取用户当前可领取分红轮次
     * @param user 用户地址
     * @return 可领取轮次数
     */
    function getClaimableRounds(address user) external view returns (uint256[] memory) {
        uint256 count = 0;
        
        // 先统计数量
        for (uint256 i = 1; i <= currentDividendRound; i++) {
            DividendPool memory pool = dividendPools[i];
            if (pool.totalAmount > 0 && 
                !dividendClaims[user][i] &&
                block.timestamp <= pool.distributionTime.add(DIVIDEND_CLAIM_WINDOW)) {
                count++;
            }
        }
        
        // 填充数组
        uint256[] memory rounds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i <= currentDividendRound; i++) {
            DividendPool memory pool = dividendPools[i];
            if (pool.totalAmount > 0 && 
                !dividendClaims[user][i] &&
                block.timestamp <= pool.distributionTime.add(DIVIDEND_CLAIM_WINDOW)) {
                rounds[index] = i;
                index++;
            }
        }
        
        return rounds;
    }
    
    // ==================== 管理函数 ====================
    
    /**
     * @dev 转移合约所有权
     * @param newOwner 新所有者地址
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "CorePool: new owner is zero address");
        owner = newOwner;
    }
    
    /**
     * @dev 紧急提取代币（仅管理员）
     * @param token 代币地址
     * @param amount 提取数量
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner, amount);
    }
}