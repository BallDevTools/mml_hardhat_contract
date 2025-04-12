// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title CryptoMembershipNFT
 * @dev สัญญาสมาชิก NFT พร้อมระบบอ้างอิงและการจัดการแผนสมาชิก (NFT ไม่สามารถโอนหรือแก้ไขได้)
 * @notice สัญญานี้จัดการระบบสมาชิก NFT ที่มีแผนการอัปเกรดและระบบอ้างอิง
 * @custom:security-contact security@example.com
 */
contract CryptoMembershipNFT is ERC721Enumerable, Ownable, ReentrancyGuard {
    uint256 private _tokenIdCounter = 0;
    IERC20 public usdtToken;
    uint8 private _tokenDecimals;

    constructor(address _usdtToken, address initialOwner) ERC721("Crypto Membership NFT", "CMNFT") Ownable(initialOwner) {
        require(_usdtToken != address(0), "Zero address not allowed");
        require(initialOwner != address(0), "Zero address not allowed");
        
        usdtToken = IERC20(_usdtToken);
        _tokenDecimals = IERC20Metadata(_usdtToken).decimals();
        require(_tokenDecimals > 0, "Invalid token decimals");
        
        _createDefaultPlans();
        
        // ตั้งค่า Default Images สำหรับ 16 แผน (ใช้ IPFS URI เป็นตัวอย่าง)
        planDefaultImages[1] = "ipfs://QmStarterImage";
        planDefaultImages[2] = "ipfs://QmExplorerImage";
        planDefaultImages[3] = "ipfs://QmTraderImage";
        planDefaultImages[4] = "ipfs://QmInvestorImage";
        planDefaultImages[5] = "ipfs://QmEliteImage";
        planDefaultImages[6] = "ipfs://QmWhaleImage";
        planDefaultImages[7] = "ipfs://QmTitanImage";
        planDefaultImages[8] = "ipfs://QmMogulImage";
        planDefaultImages[9] = "ipfs://QmTycoonImage";
        planDefaultImages[10] = "ipfs://QmLegendImage";
        planDefaultImages[11] = "ipfs://QmEmpireImage";
        planDefaultImages[12] = "ipfs://QmVisionaryImage";
        planDefaultImages[13] = "ipfs://QmMastermindImage";
        planDefaultImages[14] = "ipfs://QmTitaniumImage";
        planDefaultImages[15] = "ipfs://QmCryptoRoyaltyImage";
        planDefaultImages[16] = "ipfs://QmLegacyImage";
    }

    function _createDefaultPlans() internal {
        uint256 decimal = 10 ** _tokenDecimals;
        
        _createPlan(1 * decimal, "Starter", 4);
        _createPlan(2 * decimal, "Explorer", 4);
        _createPlan(3 * decimal, "Trader", 4);
        _createPlan(4 * decimal, "Investor", 4);
        _createPlan(5 * decimal, "Elite", 4);
        _createPlan(6 * decimal, "Whale", 4);
        _createPlan(7 * decimal, "Titan", 4);
        _createPlan(8 * decimal, "Mogul", 4);
        _createPlan(9 * decimal, "Tycoon", 4);
        _createPlan(10 * decimal, "Legend", 4);
        _createPlan(11 * decimal, "Empire", 4);
        _createPlan(12 * decimal, "Visionary", 4);
        _createPlan(13 * decimal, "Mastermind", 4);
        _createPlan(14 * decimal, "Titanium", 4);
        _createPlan(15 * decimal, "Crypto Royalty", 4);
        _createPlan(16 * decimal, "Legacy", 4);
    }

    struct MembershipPlan {
        uint256 price;
        string name;
        uint256 membersPerCycle;
        bool isActive;
    }

    struct Member {
        address upline;
        uint256 totalReferrals;
        uint256 totalEarnings;
        uint256 planId;
        uint256 cycleNumber;
        uint256 registeredAt;
    }

    struct CycleInfo {
        uint256 currentCycle;
        uint256 membersInCurrentCycle;
    }

    struct Transaction {
        address from;
        address to;
        uint256 amount;
        uint256 timestamp;
        string txType;
    }

    struct NFTImage {
        string imageURI;        // URI to the NFT image (คงที่)
        string name;            // Name of the NFT (คงที่)
        string description;     // Description of the NFT (คงที่)
        uint256 planId;         // Associated plan ID (เปลี่ยนได้เมื่ออัปเกรด)
        uint256 createdAt;      // Timestamp when the NFT was minted
    }
    
    mapping(uint256 => MembershipPlan) public plans;
    mapping(address => Member) public members;
    mapping(uint256 => CycleInfo) public planCycles;
    mapping(address => Transaction[]) public transactions;
    mapping(uint256 => NFTImage) public tokenImages;
    mapping(uint256 => string) public planDefaultImages;
    
    uint256 public planCount;
    uint256 public ownerBalance;
    uint256 public feeSystemBalance;
    uint256 public fundBalance;
    uint256 public totalCommissionPaid;
    bool public firstMemberRegistered = false;
    string private _baseTokenURI;
    address public priceFeed;
    bool public paused = false;
    uint256 public constant MAX_MEMBERS_PER_CYCLE = 4;
    uint256 public constant MAX_TRANSACTION_HISTORY = 50;

    // เพิ่ม constant สำหรับการคำนวณสัดส่วน
    uint256 private constant HUNDRED_PERCENT = 100;
    uint256 private constant COMPANY_OWNER_SHARE = 80;
    uint256 private constant COMPANY_FEE_SHARE = 20;
    uint256 private constant USER_UPLINE_SHARE = 60;
    uint256 private constant USER_FUND_SHARE = 40;

    // เพิ่ม timelock สำหรับฟังก์ชันสำคัญ
    uint256 public constant TIMELOCK_DURATION = 2 days;
    mapping(bytes32 => uint256) public timelockExpiries;

    // เพิ่ม ReentrancyLock สำหรับการโอน USDT
    bool private _inTransaction;
    modifier noReentrantTransfer() {
        require(!_inTransaction, "Reentrant transfer");
        _inTransaction = true;
        _;
        _inTransaction = false;
    }

    // เพิ่ม timelock สำหรับการถอนเงินฉุกเฉิน
    uint256 public constant EMERGENCY_TIMELOCK = 24 hours;
    uint256 public emergencyWithdrawRequestTime;

    mapping(address => uint256) private lastActionTimestamp;
    uint256 private constant MIN_ACTION_DELAY = 1 minutes;

    modifier preventFrontRunning() {
        require(block.timestamp >= lastActionTimestamp[msg.sender] + MIN_ACTION_DELAY, "Action too frequent");
        lastActionTimestamp[msg.sender] = block.timestamp;
        _;
    }

    event PlanCreated(uint256 planId, string name, uint256 price, uint256 membersPerCycle);
    event MemberRegistered(address indexed member, address indexed upline, uint256 planId, uint256 cycleNumber);
    event ReferralPaid(address indexed from, address indexed to, uint256 amount);
    event PlanUpgraded(address indexed member, uint256 oldPlanId, uint256 newPlanId, uint256 cycleNumber);
    event NewCycleStarted(uint256 planId, uint256 cycleNumber);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event ContractPaused(bool status);
    event PriceFeedUpdated(address indexed newPriceFeed);
    event MemberExited(address indexed member, uint256 refundAmount);
    event FundsDistributed(uint256 ownerAmount, uint256 feeAmount, uint256 fundAmount);
    event UplineNotified(address indexed upline, address indexed downline, uint256 downlineCurrentPlan, uint256 downlineTargetPlan);
    event PlanDefaultImageSet(uint256 indexed planId, string imageURI);
    event BatchWithdrawalProcessed(uint256 totalOwner, uint256 totalFee, uint256 totalFund);
    event EmergencyWithdrawRequested(uint256 timestamp);
    event ContractStatusUpdated(bool isPaused, uint256 totalBalance);
    event TransactionFailed(address indexed user, string reason);

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier onlyMember() {
        require(balanceOf(msg.sender) > 0, "Not a member");
        _;
    }

    function _beforeTokenTransfer(address from, address to, uint256 /* tokenId */) internal virtual {
        require(from == address(0) || to == address(0), "CryptoMembershipNFT: Token transfer is not allowed");
    }

    function createPlan(uint256 _price, string memory _name, uint256 _membersPerCycle) external onlyOwner {
        require(_membersPerCycle == MAX_MEMBERS_PER_CYCLE, "Members per cycle not allowed");
        require(bytes(_name).length > 0, "Name cannot be empty");
        require(_price > 0, "Price must be greater than zero");
        
        _createPlan(_price, _name, _membersPerCycle);
    }

    function _createPlan(uint256 _price, string memory _name, uint256 _membersPerCycle) internal {
        planCount++;
        plans[planCount] = MembershipPlan(_price, _name, _membersPerCycle, true);
        planCycles[planCount] = CycleInfo(1, 0);
        emit PlanCreated(planCount, _name, _price, _membersPerCycle);
    }

    // อนุญาตให้เจ้าของตั้งค่า Default Image (ถ้าต้องการเปลี่ยนหลัง Deploy)
    function setPlanDefaultImage(uint256 _planId, string memory _imageURI) external onlyOwner {
        require(_planId > 0 && _planId <= planCount, "Invalid plan ID");
        require(bytes(_imageURI).length > 0, "Image URI cannot be empty");
        
        planDefaultImages[_planId] = _imageURI;
        emit PlanDefaultImageSet(_planId, _imageURI);
    }

    function getNFTImage(uint256 _tokenId) external view returns (
        string memory imageURI,
        string memory name,
        string memory description,
        uint256 planId,
        uint256 createdAt
    ) {
        address tokenOwner = ownerOf(_tokenId);
        NFTImage memory image = tokenImages[_tokenId];
        
        return (
            image.imageURI,
            image.name,
            image.description,
            image.planId,
            image.createdAt
        );
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        address tokenOwner = ownerOf(_tokenId);
        NFTImage memory image = tokenImages[_tokenId];
        Member memory member = members[tokenOwner];
        
        return
            string(
                abi.encodePacked(
                    'data:application/json;base64,',
                    _base64Encode(
                        abi.encodePacked(
                            '{"name":"', image.name,
                            '", "description":"', image.description,
                            '", "image":"', image.imageURI,
                            '", "attributes": [{"trait_type": "Plan Level", "value": "',
                            _uint2str(member.planId),
                            '"}]}'
                        )
                    )
                )
            );
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function _base64Encode(bytes memory data) internal pure returns (string memory) {
        string memory TABLE = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        uint256 len = data.length;
        if (len == 0) return '';
        
        uint256 encodedLen = 4 * ((len + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        uint256 i;
        uint256 j = 0;
        
        for (i = 0; i + 3 <= len; i += 3) {
            uint256 val = uint256(uint8(data[i])) << 16 |
                          uint256(uint8(data[i + 1])) << 8 |
                          uint256(uint8(data[i + 2]));
            result[j++] = bytes(TABLE)[(val >> 18) & 63];
            result[j++] = bytes(TABLE)[(val >> 12) & 63];
            result[j++] = bytes(TABLE)[(val >> 6) & 63];
            result[j++] = bytes(TABLE)[val & 63];
        }
        
        if (i < len) {
            uint256 val = uint256(uint8(data[i])) << 16;
            if (i + 1 < len) val |= uint256(uint8(data[i + 1])) << 8;
            result[j++] = bytes(TABLE)[(val >> 18) & 63];
            result[j++] = bytes(TABLE)[(val >> 12) & 63];
            if (i + 1 < len) {
                result[j++] = bytes(TABLE)[(val >> 6) & 63];
                result[j++] = bytes(TABLE)[val & 63];
            } else {
                result[j++] = bytes(TABLE)[(val >> 6) & 63];
                result[j++] = '=';
            }
        }
        return string(result);
    }

    function registerMember(uint256 _planId, address _upline) external nonReentrant whenNotPaused {
        require(_planId > 0 && _planId <= planCount, "Invalid plan ID");
        require(_planId == 1, "New members must start at Plan 1");
        require(plans[_planId].isActive, "Plan is not active");
        require(balanceOf(msg.sender) == 0, "Already a member");
        require(bytes(planDefaultImages[_planId]).length > 0, "Default image not set for this plan");

        if (firstMemberRegistered) {
            if (_upline == address(0) || _upline == msg.sender) {
                _upline = owner();
            } else {
                require(balanceOf(_upline) > 0, "Upline is not a member");
                require(members[_upline].planId >= _planId, "Upline must be in same or higher plan");
            }
        } else {
            _upline = owner();
            firstMemberRegistered = true;
        }

        MembershipPlan memory plan = plans[_planId];
        uint256 amount = plan.price;

        uint256 balanceBefore = usdtToken.balanceOf(address(this));
        require(usdtToken.transferFrom(msg.sender, address(this), amount), "USDT transfer failed");
        uint256 balanceAfter = usdtToken.balanceOf(address(this));
        require(balanceAfter >= balanceBefore + amount, "Transfer amount mismatch");

        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;
        _safeMint(msg.sender, tokenId);

        // ตั้งค่า NFT Image คงที่จาก planDefaultImages
        string memory defaultImage = planDefaultImages[_planId];
        tokenImages[tokenId] = NFTImage(
            defaultImage,
            plans[_planId].name,
            string(abi.encodePacked("Crypto Membership NFT - ", plans[_planId].name, " Plan")),
            _planId,
            block.timestamp
        );

        CycleInfo storage cycleInfo = planCycles[_planId];
        cycleInfo.membersInCurrentCycle++;
        
        if (cycleInfo.membersInCurrentCycle >= plan.membersPerCycle) {
            cycleInfo.currentCycle++;
            cycleInfo.membersInCurrentCycle = 0;
            emit NewCycleStarted(_planId, cycleInfo.currentCycle);
        }

        members[msg.sender] = Member(
            _upline, 
            0, 
            0, 
            _planId, 
            cycleInfo.currentCycle,
            block.timestamp
        );

        _distributeFunds(amount, _upline);

        emit MemberRegistered(msg.sender, _upline, _planId, cycleInfo.currentCycle);
    }

    function _distributeFunds(uint256 _amount, address _upline) internal {
        require(_amount > 0, "Invalid amount");
        
        (uint256 userSharePercent, uint256 companySharePercent) = _getPlanShares(members[msg.sender].planId);
        require(userSharePercent + companySharePercent == HUNDRED_PERCENT, "Invalid shares total");
        
        // ป้องกัน overflow
        uint256 userShare = (_amount * userSharePercent) / HUNDRED_PERCENT;
        require(userShare <= _amount, "Share calculation overflow");
        
        uint256 companyShare = _amount - userShare;
        require(companyShare <= _amount, "Share calculation overflow");
        
        uint256 ownerShare = (companyShare * COMPANY_OWNER_SHARE) / HUNDRED_PERCENT;
        uint256 feeShare = companyShare - ownerShare;
        
        ownerBalance += ownerShare;
        feeSystemBalance += feeShare;
        
        uint256 uplineShare = (userShare * USER_UPLINE_SHARE) / HUNDRED_PERCENT;
        uint256 fundShare = userShare - uplineShare;
        
        fundBalance += fundShare;
        
        emit FundsDistributed(ownerShare, feeShare, fundShare);
        
        _handleUplinePayment(_upline, uplineShare);
    }

    function _getPlanShares(uint256 planId) internal pure returns (uint256 userShare, uint256 companyShare) {
        if (planId <= 4) {
            return (50, 50);
        } else if (planId <= 8) {
            return (55, 45);
        } else if (planId <= 12) {
            return (58, 42);
        } else {
            return (60, 40);
        }
    }

    function _handleUplinePayment(address _upline, uint256 _uplineShare) internal {
        if (_upline != address(0)) {
            if (members[_upline].planId >= members[msg.sender].planId) {
                _payReferralCommission(msg.sender, _upline, _uplineShare);
                members[_upline].totalReferrals += 1;
            } else {
                ownerBalance += _uplineShare;
            }
        } else {
            ownerBalance += _uplineShare;
        }
    }

    function _payReferralCommission(address _from, address _to, uint256 _amount) internal noReentrantTransfer {
        Member storage upline = members[_to];
        uint256 commission = _amount;

        require(usdtToken.transfer(_to, commission), "USDT transfer to upline failed");
        
        upline.totalEarnings += commission;
        totalCommissionPaid += commission;
        
        _addTransaction(_from, _to, commission, "referral");
        
        emit ReferralPaid(_from, _to, commission);
    }

    function _addTransaction(address _from, address _to, uint256 _amount, string memory _type) internal {
        Transaction[] storage userTxs = transactions[_to];
        
        // ใช้ circular buffer แทนการ shift array
        uint256 nextIndex = userTxs.length < MAX_TRANSACTION_HISTORY ? 
            userTxs.length : 
            block.timestamp % MAX_TRANSACTION_HISTORY;
        
        if (userTxs.length < MAX_TRANSACTION_HISTORY) {
            userTxs.push(Transaction(_from, _to, _amount, block.timestamp, _type));
        } else {
            userTxs[nextIndex] = Transaction(_from, _to, _amount, block.timestamp, _type);
        }
    }

    function upgradePlan(uint256 _newPlanId) external nonReentrant whenNotPaused onlyMember {
        require(!_inTransaction, "Transaction in progress");
        require(msg.sender != address(0), "Invalid sender");
        require(members[msg.sender].registeredAt > 0, "Member not registered");
        require(_newPlanId > 0 && _newPlanId <= planCount, "Invalid plan ID");
        require(plans[_newPlanId].isActive, "Plan is not active");

        Member storage member = members[msg.sender];
        require(_newPlanId > member.planId, "Can only upgrade to higher plan");
        require(_newPlanId == member.planId + 1, "Cannot skip plans, must upgrade sequentially");

        uint256 priceDifference = plans[_newPlanId].price - plans[member.planId].price;
        require(priceDifference > 0, "Invalid price difference");
        
        uint256 balanceBefore = usdtToken.balanceOf(address(this));
        require(usdtToken.transferFrom(msg.sender, address(this), priceDifference), "USDT transfer failed");
        uint256 balanceAfter = usdtToken.balanceOf(address(this));
        require(balanceAfter >= balanceBefore + priceDifference, "Transfer amount mismatch");

        uint256 oldPlanId = member.planId;
        address upline = member.upline;

        CycleInfo storage cycleInfo = planCycles[_newPlanId];
        cycleInfo.membersInCurrentCycle++;
        
        if (cycleInfo.membersInCurrentCycle >= plans[_newPlanId].membersPerCycle) {
            cycleInfo.currentCycle++;
            cycleInfo.membersInCurrentCycle = 0;
            emit NewCycleStarted(_newPlanId, cycleInfo.currentCycle);
        }

        member.cycleNumber = cycleInfo.currentCycle;
        member.planId = _newPlanId;

        if (upline != address(0) && members[upline].planId < _newPlanId) {
            emit UplineNotified(upline, msg.sender, oldPlanId, _newPlanId);
        }

        _distributeFunds(priceDifference, upline);

        // อัปเดตเฉพาะ planId ใน tokenImages ไม่เปลี่ยนรูปภาพ
        uint256 tokenId = tokenOfOwnerByIndex(msg.sender, 0);
        tokenImages[tokenId].planId = _newPlanId;

        emit PlanUpgraded(msg.sender, oldPlanId, _newPlanId, cycleInfo.currentCycle);
    }

    function exitMembership() external nonReentrant whenNotPaused onlyMember {
        Member storage member = members[msg.sender];
        require(block.timestamp > member.registeredAt + 30 days, "Exit unavailable before 30 days");
        
        uint256 planPrice = plans[member.planId].price;
        uint256 refundAmount = (planPrice * 30) / 100;
        
        require(fundBalance >= refundAmount, "Insufficient fund balance for refund");
        
        fundBalance -= refundAmount;
        
        uint256 tokenId = tokenOfOwnerByIndex(msg.sender, 0);
        delete tokenImages[tokenId];
        
        _burn(tokenId);
        delete members[msg.sender];
        
        require(usdtToken.transfer(msg.sender, refundAmount), "USDT transfer failed");
        
        emit MemberExited(msg.sender, refundAmount);
    }
    
    function withdrawOwnerBalance(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= ownerBalance, "Insufficient owner balance");
        ownerBalance -= amount;
        require(usdtToken.transfer(owner(), amount), "USDT transfer failed");
    }

    function withdrawFeeSystemBalance(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= feeSystemBalance, "Insufficient fee balance");
        feeSystemBalance -= amount;
        require(usdtToken.transfer(owner(), amount), "USDT transfer failed");
    }

    function withdrawFundBalance(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= fundBalance, "Insufficient fund balance");
        fundBalance -= amount;
        require(usdtToken.transfer(owner(), amount), "USDT transfer failed");
    }

    function getPlanCycleInfo(uint256 _planId) external view returns (
        uint256 currentCycle, 
        uint256 membersInCurrentCycle, 
        uint256 membersPerCycle
    ) {
        require(_planId > 0 && _planId <= planCount, "Invalid plan ID");
        CycleInfo memory cycleInfo = planCycles[_planId];
        return (cycleInfo.currentCycle, cycleInfo.membersInCurrentCycle, plans[_planId].membersPerCycle);
    }

    function updateMembersPerCycle(uint256 _planId, uint256 _newMembersPerCycle) external onlyOwner {
        require(_planId > 0 && _planId <= planCount, "Invalid plan ID");
        require(_newMembersPerCycle == MAX_MEMBERS_PER_CYCLE, "Invalid members per cycle");
        plans[_planId].membersPerCycle = _newMembersPerCycle;
    }

    function setBaseURI(string memory baseURI) external onlyOwner {
        require(bytes(baseURI).length > 0, "Base URI cannot be empty");
        _baseTokenURI = baseURI;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function setPlanStatus(uint256 _planId, bool _isActive) external onlyOwner {
        require(_planId > 0 && _planId <= planCount, "Invalid plan ID");
        plans[_planId].isActive = _isActive;
    }

    function getMemberTransactions(address _member) external view returns (Transaction[] memory) {
        return transactions[_member];
    }

    function getSystemStats() external view returns (
        uint256 totalMembers, 
        uint256 totalRevenue, 
        uint256 totalCommission, 
        uint256 ownerFunds, 
        uint256 feeFunds, 
        uint256 fundFunds
    ) {
        return (
            totalSupply(),
            ownerBalance + feeSystemBalance + fundBalance + totalCommissionPaid,
            totalCommissionPaid,
            ownerBalance,
            feeSystemBalance,
            fundBalance
        );
    }
    
    function setPriceFeed(address _priceFeed) external onlyOwner {
        require(_priceFeed != address(0), "Invalid price feed address");
        priceFeed = _priceFeed;
        emit PriceFeedUpdated(_priceFeed);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit ContractPaused(_paused);
    }

    function requestEmergencyWithdraw() external onlyOwner {
        emergencyWithdrawRequestTime = block.timestamp;
        emit EmergencyWithdrawRequested(block.timestamp);
    }

    function emergencyWithdraw() external onlyOwner nonReentrant {
        require(emergencyWithdrawRequestTime > 0, "No withdrawal requested");
        require(block.timestamp >= emergencyWithdrawRequestTime + EMERGENCY_TIMELOCK, "Timelock not expired");
        
        uint256 contractBalance = usdtToken.balanceOf(address(this));
        require(contractBalance > 0, "No funds available");
        
        // Reset timelock
        emergencyWithdrawRequestTime = 0;
        
        ownerBalance = 0;
        feeSystemBalance = 0;
        fundBalance = 0;
        
        require(usdtToken.transfer(owner(), contractBalance), "USDT transfer failed");
        
        emit EmergencyWithdraw(owner(), contractBalance);
    }
    
    function restartAfterPause() external onlyOwner {
        require(paused, "Contract is not paused");
        paused = false;
        emit ContractPaused(false);
    }

    // เพิ่ม batch withdrawal
    struct WithdrawalRequest {
        address recipient;
        uint256 amount;
        uint256 balanceType; // 0: owner, 1: fee, 2: fund
    }

    function batchWithdraw(WithdrawalRequest[] calldata requests) external onlyOwner nonReentrant {
        require(requests.length > 0, "Empty request array");
        require(requests.length <= 20, "Too many requests"); // จำกัดจำนวน batch
        
        uint256 totalRequested;
        for(uint256 i = 0; i < requests.length;) {
            require(requests[i].recipient != address(0), "Invalid recipient");
            require(requests[i].amount > 0, "Invalid amount");
            require(requests[i].balanceType <= 2, "Invalid balance type");
            
            totalRequested += requests[i].amount;
            require(totalRequested >= requests[i].amount, "Overflow check");
            
            unchecked { ++i; }
        }
        
        uint256 totalOwner;
        uint256 totalFee;
        uint256 totalFund;
        
        for (uint256 i = 0; i < requests.length;) {
            WithdrawalRequest calldata req = requests[i];
            
            if (req.balanceType == 0) {
                require(req.amount <= ownerBalance, "Insufficient owner balance");
                totalOwner += req.amount;
                ownerBalance -= req.amount;
            } else if (req.balanceType == 1) {
                require(req.amount <= feeSystemBalance, "Insufficient fee balance");
                totalFee += req.amount;
                feeSystemBalance -= req.amount;
            } else {
                require(req.amount <= fundBalance, "Insufficient fund balance");
                totalFund += req.amount;
                fundBalance -= req.amount;
            }
            
            require(usdtToken.transfer(req.recipient, req.amount), "USDT transfer failed");
            
            unchecked { ++i; }
        }
        
        emit BatchWithdrawalProcessed(totalOwner, totalFee, totalFund);
    }

    function getContractStatus() external view returns (
        bool isPaused,
        uint256 totalBalance,
        uint256 memberCount,
        uint256 currentPlanCount,
        bool hasEmergencyRequest,
        uint256 emergencyTimeRemaining
    ) {
        uint256 timeRemaining = emergencyWithdrawRequestTime > 0 ? 
            emergencyWithdrawRequestTime + EMERGENCY_TIMELOCK - block.timestamp : 0;
        
        return (
            paused,
            usdtToken.balanceOf(address(this)),
            totalSupply(),
            planCount,
            emergencyWithdrawRequestTime > 0,
            timeRemaining
        );
    }
}