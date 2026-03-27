// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IPaulBaileyToken {
    function balanceOf(address account) external view returns (uint256);
    function sell(uint256 tokenAmount) external;
    function mintReward(address to, uint256 amount) external;
}

interface IReferralReward {
    function updateTeamPerformance(address user, int256 amountChange, bool isDeposit) external;
    function onWithdrawClearContribution(address user) external;
    function distributeStaticReward(address user, uint256 rewardAmount) external returns (uint256);
}

interface IDEXRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

contract StakingPool is ReentrancyGuard, Ownable {
    
    uint256 public constant MIN_DEPOSIT = 100 * 10**18;
    uint256 public constant DAILY_DECAY_BPS = 100;
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant UNCLAIM_EXPIRE_TIME = 86400;
    
    IERC20 public immutable usdToken;
    IPaulBaileyToken public immutable pblToken;
    IReferralReward public referralContract;
    IDEXRouter public dexRouter;
    address public pblUsdPair;
    
    struct UserStake {
        uint256 principal;
        uint256 contribution;
        uint256 lastUpdateTime;
        uint256 lastClaimTime;
        uint256 lockUntil;
        uint256 pendingRewards;
        uint256 contributionSnapshot;
        uint256 globalDecayFactorSnapshot;
        uint256 totalDeposited; // 新增：累计入金金额
    }
    
    uint256 public globalDecayFactor = 1e18;
    uint256 public lastGlobalDecayUpdate;
    uint256 public totalActiveContribution;
    mapping(address => UserStake) public userStakes;
    
    uint256 public totalRewardToDistribute;
    uint256 public lastRewardDistributionTime;
    
    address public privateSaleContract;
    uint256 public privateSaleMultiplier = 3;
    mapping(address => bool) public isFromPrivateSale; // 新增：记录用户是否来自私募
    
    event Deposited(address indexed user, uint256 usdAmount, uint256 principal, uint256 contributionAdded, uint256 lockUntil);
    event RewardsDistributed(uint256 totalAmount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event PrincipalWithdrawn(address indexed user, uint256 amount);
    event PrivateSaleSet(address indexed contractAddress);
    event ReferralContractSet(address indexed contractAddress);
    event DailyDecayApplied(uint256 newGlobalDecayFactor, uint256 timestamp);
    event LiquidityAdded(uint256 usdAmount, uint256 pblAmount, uint256 liquidity);
    
    constructor(
        address _usdToken,
        address _pblToken,
        address _dexRouter,
        address _pblUsdPair,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_usdToken != address(0) && _pblToken != address(0), "Zero address");
        require(_dexRouter != address(0) && _pblUsdPair != address(0), "DEX addresses required");
        
        usdToken = IERC20(_usdToken);
        pblToken = IPaulBaileyToken(_pblToken);
        dexRouter = IDEXRouter(_dexRouter);
        pblUsdPair = _pblUsdPair;
        lastGlobalDecayUpdate = block.timestamp;
    }
    
    // --- 核心功能：质押 ---
    function deposit(uint256 usdtAmount) external nonReentrant {
        require(usdtAmount >= MIN_DEPOSIT, "Below minimum deposit");
        require(usdtAmount % (100 * 10**18) == 0, "Must be multiple of 100");
        
        _updateUserDecay(msg.sender);
        
        require(usdToken.transferFrom(msg.sender, address(this), usdtAmount), "Transfer failed");
        
        uint256 toLiquidity = (usdtAmount * 30) / 100;
        uint256 toPrincipal = usdtAmount - toLiquidity;
        
        // 添加流动性
        _addToLiquidity(toLiquidity);
        
        UserStake storage user = userStakes[msg.sender];
        user.principal += toPrincipal;
        user.totalDeposited += usdtAmount; // 记录累计入金
        
        // 设置锁定期
        if (user.lockUntil < block.timestamp) {
            user.lockUntil = block.timestamp + 24 hours;
        } else {
            user.lockUntil += 24 hours;
        }
        
        // 计算贡献值
        uint256 contributionToAdd = usdtAmount;
        if (isFromPrivateSale[msg.sender]) {
            contributionToAdd *= privateSaleMultiplier;
        }
        
        _addContribution(msg.sender, contributionToAdd);
        
        // 更新推荐系统
        if (address(referralContract) != address(0)) {
            referralContract.updateTeamPerformance(msg.sender, int256(usdtAmount), true);
        }
        
        emit Deposited(msg.sender, usdtAmount, toPrincipal, contributionToAdd, user.lockUntil);
    }
    
    // --- 核心功能：提现 ---
    function withdrawPrincipal(uint256 amount) external nonReentrant {
        require(amount > 0, "Cannot withdraw zero");
        
        UserStake storage user = userStakes[msg.sender];
        require(block.timestamp >= user.lockUntil, "Funds are locked");
        require(user.principal >= amount, "Insufficient principal");
        
        _updateUserDecay(msg.sender);
        
        user.principal -= amount;
        _clearContribution(msg.sender);
        
        if (address(referralContract) != address(0)) {
            referralContract.onWithdrawClearContribution(msg.sender);
            referralContract.updateTeamPerformance(msg.sender, -int256(amount), false);
        }
        
        require(usdToken.transfer(msg.sender, amount), "Transfer failed");
        emit PrincipalWithdrawn(msg.sender, amount);
    }
    
    // --- 贡献值系统 ---
    function _updateGlobalDecay() internal {
        uint256 timePassed = block.timestamp - lastGlobalDecayUpdate;
        if (timePassed < SECONDS_PER_DAY) return;
        
        uint256 daysPassed = timePassed / SECONDS_PER_DAY;
        if (daysPassed == 0) return;
        
        // 每日衰减1%
        for (uint256 i = 0; i < daysPassed; i++) {
            globalDecayFactor = (globalDecayFactor * 9900) / 10000;
        }
        
        lastGlobalDecayUpdate = block.timestamp;
        totalActiveContribution = (totalActiveContribution * globalDecayFactor) / 1e18;
        
        emit DailyDecayApplied(globalDecayFactor, block.timestamp);
    }
    
    function _updateUserDecay(address user) internal {
        _updateGlobalDecay();
        
        UserStake storage stake = userStakes[user];
        if (stake.contribution == 0) return;
        
        if (stake.contributionSnapshot > 0) {
            uint256 decayedContribution = (stake.contributionSnapshot * globalDecayFactor) / stake.globalDecayFactorSnapshot;
            totalActiveContribution = totalActiveContribution - stake.contribution + decayedContribution;
            stake.contribution = decayedContribution;
        }
        
        stake.contributionSnapshot = stake.contribution;
        stake.globalDecayFactorSnapshot = globalDecayFactor;
        stake.lastUpdateTime = block.timestamp;
    }
    
    function _addContribution(address user, uint256 amount) internal {
        UserStake storage stake = userStakes[user];
        
        if (stake.contribution > 0) {
            _updateUserDecay(user);
        } else {
            stake.contributionSnapshot = 0;
            stake.globalDecayFactorSnapshot = globalDecayFactor;
        }
        
        stake.contribution += amount;
        totalActiveContribution += amount;
        stake.contributionSnapshot = stake.contribution;
        stake.lastUpdateTime = block.timestamp;
    }
    
    function _clearContribution(address user) internal {
        UserStake storage stake = userStakes[user];
        
        if (stake.contribution > 0) {
            _updateUserDecay(user);
            totalActiveContribution -= stake.contribution;
            stake.contribution = 0;
            stake.contributionSnapshot = 0;
        }
    }
    
    // --- 奖励系统 ---
    function claimRewards() external nonReentrant {
        _updateUserDecay(msg.sender);
        
        UserStake storage stake = userStakes[msg.sender];
        require(stake.contribution > 0, "No contribution");
        require(totalActiveContribution > 0, "No total contribution");
        
        uint256 userShare = (stake.contribution * 1e18) / totalActiveContribution;
        uint256 pending = (totalRewardToDistribute * userShare) / 1e18;
        
        require(pending > 0, "No rewards to claim");
        
        // 检查过期
        if (stake.lastClaimTime > 0 && block.timestamp > stake.lastClaimTime + UNCLAIM_EXPIRE_TIME) {
            stake.pendingRewards = 0;
        } else {
            stake.pendingRewards += pending;
        }
        
        uint256 toClaim = stake.pendingRewards;
        
        // 调用推荐奖励分配
        if (address(referralContract) != address(0) && toClaim > 0) {
            //实际分发给上级的金额
            referralContract.distributeStaticReward(msg.sender, toClaim);
            
        }
        
        stake.pendingRewards = 0;
        stake.lastClaimTime = block.timestamp;
        totalRewardToDistribute -= toClaim;
        
        pblToken.mintReward(msg.sender, toClaim);
        emit RewardsClaimed(msg.sender, toClaim);
    }
    
    // --- 辅助功能 ---
    function _addToLiquidity(uint256 usdAmount) internal {
        require(usdAmount > 0, "No liquidity to add");
        
        // 授权Router使用USDT
        usdToken.approve(address(dexRouter), usdAmount);
        
        // 假设有足够的保罗币余额（需在部署时预存）
        uint256 pblBalance = pblToken.balanceOf(address(this));
        require(pblBalance >= usdAmount, "Insufficient PBL for liquidity");
        
        // 计算需要添加的保罗币数量（1:1比例）
        uint256 pblAmount = usdAmount;
        
        // 授权Router使用保罗币
        // 注意：由于保罗币禁用了approve，需要特殊处理
        // 简化：假设已有足够授权
        
        // 添加流动性
        try dexRouter.addLiquidity(
            address(usdToken),  // tokenA (USDT)
            address(pblToken),  // tokenB (PBL)
            usdAmount,          // amountADesired
            pblAmount,          // amountBDesired
            0,                  // amountAMin
            0,                  // amountBMin
            address(this),      // to
            block.timestamp + 300 // deadline
        ) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
            emit LiquidityAdded(amountA, amountB, liquidity);
        } catch {
            // 简化处理：如果DEX调用失败，将资金退回合约
            // 实际部署需要更完善的错误处理
        }
    }
    
    // --- 管理功能 ---
    function setPrivateSaleUser(address user, bool isPrivateSaleUser) external onlyOwner {
        isFromPrivateSale[user] = isPrivateSaleUser;
    }
    
    function setPrivateSaleContract(address _privateSaleContract) external onlyOwner {
        privateSaleContract = _privateSaleContract;
        emit PrivateSaleSet(_privateSaleContract);
    }
    
    function setReferralContract(address _referralContract) external onlyOwner {
        referralContract = IReferralReward(_referralContract);
        emit ReferralContractSet(_referralContract);
    }
    
    function setPrivateSaleMultiplier(uint256 multiplier) external onlyOwner {
        require(multiplier >= 1, "Multiplier must be >= 1");
        privateSaleMultiplier = multiplier;
    }
    
    function distributeRewards(uint256 rewardAmount) external onlyOwner {
        require(rewardAmount > 0, "No reward to distribute");
        require(totalActiveContribution > 0, "No active contributors");
        
        _updateGlobalDecay();
        totalRewardToDistribute += rewardAmount;
        lastRewardDistributionTime = block.timestamp;
        
        emit RewardsDistributed(rewardAmount);
    }
    
    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }
    
    // --- 视图函数 ---
    function getWithdrawablePrincipal(address user) external view returns (uint256) {
        UserStake storage stake = userStakes[user];
        if (block.timestamp >= stake.lockUntil) {
            return stake.principal;
        }
        return 0;
    }
    
    function getPendingRewards(address user) external view returns (uint256) {
        UserStake storage stake = userStakes[user];
        
        if (stake.contribution == 0 || totalActiveContribution == 0) {
            return 0;
        }
        
        uint256 userShare = (stake.contribution * 1e18) / totalActiveContribution;
        uint256 pending = (totalRewardToDistribute * userShare) / 1e18;
        uint256 total = pending + stake.pendingRewards;
        
        if (stake.lastClaimTime > 0 && block.timestamp > stake.lastClaimTime + UNCLAIM_EXPIRE_TIME) {
            return 0;
        }
        
        return total;
    }
    
    function updateDecay() external {
        _updateGlobalDecay();
    }
    
    function getUserInfo(address user) external view returns (
        uint256 principal,
        uint256 contribution,
        uint256 lockUntil,
        uint256 pendingRewards,
        uint256 lastClaimTime,
        uint256 totalDeposited
    ) {
        UserStake storage stake = userStakes[user];
        return (
            stake.principal,
            stake.contribution,
            stake.lockUntil,
            stake.pendingRewards,
            stake.lastClaimTime,
            stake.totalDeposited
        );
    }
    
    function getGlobalDecayInfo() external view returns (
        uint256 decayFactor,
        uint256 lastUpdate,
        uint256 totalContribution
    ) {
        return (globalDecayFactor, lastGlobalDecayUpdate, totalActiveContribution);
    }
}