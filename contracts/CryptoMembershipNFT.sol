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
    // ===== STORAGE OPTIMIZATION =====
    // Consolidate related state variables to use fewer storage slots
    struct ContractState {
        uint256 tokenIdCounter;
        uint256 planCount;
        uint256 ownerBalance;
        uint256 feeSystemBalance;
        uint256 fundBalance;
        uint256 totalCommissionPaid;
        bool firstMemberRegistered;
        bool paused;
        uint256 emergencyWithdrawRequestTime;
        uint256 transactionCounter;
    }
    
    ContractState private state;
    
    IERC20 public immutable usdtToken;
    uint8 private immutable _tokenDecimals;
    address public priceFeed;
    string private _baseTokenURI;
    
    // Constants defined once to save gas
    uint256 private constant HUNDRED_PERCENT = 100;
    uint256 private constant COMPANY_OWNER_SHARE = 80;
    uint256 private constant COMPANY_FEE_SHARE = 20;
    uint256 private constant USER_UPLINE_SHARE = 60;
    uint256 private constant USER_FUND_SHARE = 40;
    uint256 public constant MAX_MEMBERS_PER_CYCLE = 4;
    uint256 public constant MAX_TRANSACTION_HISTORY = 50;
    uint256 public constant TIMELOCK_DURATION = 2 days;
    uint256 public constant EMERGENCY_TIMELOCK = 24 hours;
    uint256 private constant MIN_ACTION_DELAY = 1 minutes;
    
    // Main data structures
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
    
    // ===== MAPPINGS =====
    // Use packed mappings for related data where possible
    mapping(uint256 => MembershipPlan) public plans;
    mapping(address => Member) public members;
    mapping(uint256 => CycleInfo) public planCycles;
    mapping(address => Transaction[]) public transactions;
    mapping(uint256 => NFTImage) public tokenImages;
    mapping(uint256 => string) public planDefaultImages;
    mapping(bytes32 => uint256) public timelockExpiries;
    mapping(address => uint256) private lastActionTimestamp;
    
    // Reentrancy protection specific for transfers
    bool private _inTransaction;
    
    // ===== EVENTS =====
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
    event TimelockUpdated(uint256 newDuration);
    event ReferralLoopDetected(address indexed member, address indexed upline);
    event EmergencyWithdrawInitiated(uint256 timestamp, uint256 amount);
    event MetadataUpdated(uint256 indexed tokenId, string newURI);
    event PlanUpgradeRequested(address indexed member, uint256 currentPlan, uint256 targetPlan);
    
    // ===== MODIFIERS =====
    modifier whenNotPaused() {
        require(!state.paused, "Contract is paused");
        _;
    }

    modifier onlyMember() {
        require(balanceOf(msg.sender) > 0, "Not a member");
        _;
    }
    
    modifier noReentrantTransfer() {
        require(!_inTransaction, "Reentrant transfer");
        _inTransaction = true;
        _;
        _inTransaction = false;
    }
    
    modifier preventFrontRunning() {
        require(block.timestamp >= lastActionTimestamp[msg.sender] + MIN_ACTION_DELAY, "Action too frequent");
        lastActionTimestamp[msg.sender] = block.timestamp;
        _;
    }

    modifier noReferralLoop(address _upline) {
        require(!_isReferralLoop[_upline], "Referral loop detected");
        _;
    }

    modifier validAddress(address _addr) {
        require(_addr != address(0), "Zero address not allowed");
        _;
    }

    // ===== CONSTRUCTOR =====
    constructor(address _usdtToken, address initialOwner) ERC721("Crypto Membership NFT", "CMNFT") Ownable(initialOwner) validAddress(_usdtToken) validAddress(initialOwner) {
        require(_usdtToken != address(0), "Zero address not allowed");
        require(initialOwner != address(0), "Zero address not allowed");
        
        usdtToken = IERC20(_usdtToken);
        _tokenDecimals = IERC20Metadata(_usdtToken).decimals();
        require(_tokenDecimals > 0, "Invalid token decimals");
        
        _createDefaultPlans();
        _setupDefaultImages();
    }

    // ===== INTERNAL SETUP FUNCTIONS =====
    function _setupDefaultImages() internal {
        // Set default images in a loop to reduce bytecode size
        string[16] memory baseURIs = [
            "ipfs://QmStarterImage",
            "ipfs://QmExplorerImage",
            "ipfs://QmTraderImage",
            "ipfs://QmInvestorImage",
            "ipfs://QmEliteImage",
            "ipfs://QmWhaleImage",
            "ipfs://QmTitanImage",
            "ipfs://QmMogulImage",
            "ipfs://QmTycoonImage",
            "ipfs://QmLegendImage",
            "ipfs://QmEmpireImage",
            "ipfs://QmVisionaryImage",
            "ipfs://QmMastermindImage",
            "ipfs://QmTitaniumImage",
            "ipfs://QmCryptoRoyaltyImage",
            "ipfs://QmLegacyImage"
        ];
        
        for (uint256 i = 0; i < baseURIs.length;) {
            planDefaultImages[i + 1] = baseURIs[i];
            unchecked { ++i; }
        }
    }

    function _createDefaultPlans() internal {
        uint256 decimal = 10 ** _tokenDecimals;
        
        // Create plans with a loop to reduce bytecode size
        string[16] memory planNames = [
            "Starter", "Explorer", "Trader", "Investor",
            "Elite", "Whale", "Titan", "Mogul",
            "Tycoon", "Legend", "Empire", "Visionary",
            "Mastermind", "Titanium", "Crypto Royalty", "Legacy"
        ];
        
        for (uint256 i = 0; i < planNames.length;) {
            _createPlan((i + 1) * decimal, planNames[i], MAX_MEMBERS_PER_CYCLE);
            unchecked { ++i; }
        }
    }

    // ===== TOKEN TRANSFER RESTRICTION =====
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal virtual {
        require(from == address(0) || to == address(0), "CryptoMembershipNFT: Token transfer is not allowed");
    }

    // ===== PLAN MANAGEMENT =====
    function createPlan(uint256 _price, string calldata _name, uint256 _membersPerCycle) external onlyOwner {
        require(_membersPerCycle == MAX_MEMBERS_PER_CYCLE, "Members per cycle not allowed");
        require(bytes(_name).length > 0, "Name cannot be empty");
        require(_price > 0, "Price must be greater than zero");
        
        _createPlan(_price, _name, _membersPerCycle);
    }

    function _createPlan(uint256 _price, string memory _name, uint256 _membersPerCycle) internal {
        unchecked { state.planCount++; }
        plans[state.planCount] = MembershipPlan(_price, _name, _membersPerCycle, true);
        planCycles[state.planCount] = CycleInfo(1, 0);
        emit PlanCreated(state.planCount, _name, _price, _membersPerCycle);
    }

    function setPlanDefaultImage(uint256 _planId, string calldata _imageURI) external onlyOwner {
        require(_planId > 0 && _planId <= state.planCount, "Invalid plan ID");
        require(bytes(_imageURI).length > 0, "Image URI cannot be empty");
        
        planDefaultImages[_planId] = _imageURI;
        emit PlanDefaultImageSet(_planId, _imageURI);
    }

    // ===== NFT METADATA =====
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
        require(_exists(_tokenId), "URI query for nonexistent token");
        
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

    // ===== ENCODING UTILITIES =====
    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            unchecked { ++len; }
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            unchecked { k = k - 1; }
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
        
        // Use unchecked math to save gas where safe
        uint256 encodedLen = 4 * ((len + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        uint256 i;
        uint256 j = 0;
        
        for (i = 0; i + 3 <= len;) {
            uint256 val = uint256(uint8(data[i])) << 16 |
                          uint256(uint8(data[i + 1])) << 8 |
                          uint256(uint8(data[i + 2]));
            result[j++] = bytes(TABLE)[(val >> 18) & 63];
            result[j++] = bytes(TABLE)[(val >> 12) & 63];
            result[j++] = bytes(TABLE)[(val >> 6) & 63];
            result[j++] = bytes(TABLE)[val & 63];
            unchecked { i += 3; }
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

    // ===== MEMBER MANAGEMENT =====
    function registerMember(uint256 _planId, address _upline) external nonReentrant whenNotPaused preventFrontRunning validAddress(_upline) noReferralLoop(_upline) {
        require(_planId > 0 && _planId <= state.planCount, "Invalid plan ID");
        require(_planId == 1, "New members must start at Plan 1");
        require(plans[_planId].isActive, "Plan is not active");
        require(balanceOf(msg.sender) == 0, "Already a member");
        require(bytes(planDefaultImages[_planId]).length > 0, "Default image not set for this plan");

        // Validate upline
        address finalUpline;
        if (state.firstMemberRegistered) {
            if (_upline == address(0) || _upline == msg.sender) {
                finalUpline = owner();
            } else {
                require(balanceOf(_upline) > 0, "Upline is not a member");
                require(members[_upline].planId >= _planId, "Upline must be in same or higher plan");
                finalUpline = _upline;
            }
        } else {
            finalUpline = owner();
            state.firstMemberRegistered = true;
        }

        MembershipPlan memory plan = plans[_planId];
        uint256 amount = plan.price;

        // Safely transfer tokens with validation
        _safeTransferFrom(msg.sender, address(this), amount);

        // Mint NFT
        uint256 tokenId = state.tokenIdCounter;
        unchecked { state.tokenIdCounter++; }
        _safeMint(msg.sender, tokenId);

        // Set NFT metadata
        string memory defaultImage = planDefaultImages[_planId];
        tokenImages[tokenId] = NFTImage(
            defaultImage,
            plans[_planId].name,
            string(abi.encodePacked("Crypto Membership NFT - ", plans[_planId].name, " Plan")),
            _planId,
            block.timestamp
        );

        // Update cycle info
        CycleInfo storage cycleInfo = planCycles[_planId];
        unchecked { cycleInfo.membersInCurrentCycle++; }
        
        if (cycleInfo.membersInCurrentCycle >= plan.membersPerCycle) {
            unchecked { 
                cycleInfo.currentCycle++;
                cycleInfo.membersInCurrentCycle = 0;
            }
            emit NewCycleStarted(_planId, cycleInfo.currentCycle);
        }

        // Create member record
        members[msg.sender] = Member(
            finalUpline, 
            0, 
            0, 
            _planId, 
            cycleInfo.currentCycle,
            block.timestamp
        );

        // Distribute funds
        _distributeFunds(amount, finalUpline);

        // Add referral depth check
        uint256 depth = 0;
        address currentUpline = finalUpline;
        while (currentUpline != address(0) && depth < MAX_REFERRAL_DEPTH) {
            depth++;
            currentUpline = members[currentUpline].upline;
        }
        require(depth < MAX_REFERRAL_DEPTH, "Referral chain too deep");

        emit MemberRegistered(msg.sender, finalUpline, _planId, cycleInfo.currentCycle);
    }

    // ===== SECURE TOKEN TRANSFER FUNCTIONS =====
    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        uint256 balanceBefore = usdtToken.balanceOf(to);
        require(usdtToken.transferFrom(from, to, amount), "Token transfer failed");
        uint256 balanceAfter = usdtToken.balanceOf(to);
        require(balanceAfter >= balanceBefore + amount, "Transfer amount verification failed");
    }
    
    function _safeTransfer(address to, uint256 amount) internal {
        uint256 balanceBefore = usdtToken.balanceOf(to);
        require(usdtToken.transfer(to, amount), "Token transfer failed");
        uint256 balanceAfter = usdtToken.balanceOf(to);
        require(balanceAfter >= balanceBefore + amount, "Transfer amount verification failed");
    }

    // ===== FUND DISTRIBUTION =====
    function _distributeFunds(uint256 _amount, address _upline) internal {
        require(_amount > 0, "Invalid amount");
        
        // Lock in the upline to prevent changes during execution
        address currentUpline = _upline;
        
        // Get shares based on plan
        (uint256 userSharePercent, uint256 companySharePercent) = _getPlanShares(members[msg.sender].planId);
        require(userSharePercent + companySharePercent == HUNDRED_PERCENT, "Invalid shares total");
        
        // Calculate shares using unchecked for gas optimization where safe
        uint256 userShare;
        uint256 companyShare;
        unchecked {
            userShare = (_amount * userSharePercent) / HUNDRED_PERCENT;
            companyShare = _amount - userShare;
        }
        
        // Double-check calculation
        require(userShare + companyShare == _amount, "Distribution calculation error");
        
        uint256 ownerShare;
        uint256 feeShare;
        unchecked {
            ownerShare = (companyShare * COMPANY_OWNER_SHARE) / HUNDRED_PERCENT;
            feeShare = companyShare - ownerShare;
        }
        
        uint256 uplineShare;
        uint256 fundShare;
        unchecked {
            uplineShare = (userShare * USER_UPLINE_SHARE) / HUNDRED_PERCENT;
            fundShare = userShare - uplineShare;
            
            state.ownerBalance += ownerShare;
            state.feeSystemBalance += feeShare;
            state.fundBalance += fundShare;
        }
        
        emit FundsDistributed(ownerShare, feeShare, fundShare);
        
        _handleUplinePayment(currentUpline, uplineShare);
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
                unchecked { members[_upline].totalReferrals += 1; }
            } else {
                unchecked { state.ownerBalance += _uplineShare; }
            }
        } else {
            unchecked { state.ownerBalance += _uplineShare; }
        }
    }

    function _payReferralCommission(address _from, address _to, uint256 _amount) internal noReentrantTransfer {
        Member storage upline = members[_to];
        uint256 commission = _amount;

        _safeTransfer(_to, commission);
        
        unchecked {
            upline.totalEarnings += commission;
            state.totalCommissionPaid += commission;
        }
        
        _addTransaction(_from, _to, commission, "referral");
        
        emit ReferralPaid(_from, _to, commission);
    }

    // ===== TRANSACTION HISTORY =====
    function _addTransaction(address _from, address _to, uint256 _amount, string memory _type) internal {
        Transaction[] storage userTxs = transactions[_to];
        
        // Use a persistent counter for more gas-efficient circular buffer
        if (userTxs.length < MAX_TRANSACTION_HISTORY) {
            userTxs.push(Transaction(_from, _to, _amount, block.timestamp, _type));
        } else {
            unchecked { state.transactionCounter = (state.transactionCounter + 1) % MAX_TRANSACTION_HISTORY; }
            userTxs[state.transactionCounter] = Transaction(_from, _to, _amount, block.timestamp, _type);
        }
    }

    // ===== PLAN UPGRADE =====
    function upgradePlan(uint256 _newPlanId) external nonReentrant whenNotPaused onlyMember preventFrontRunning {
        require(block.timestamp >= _lastUpgradeRequest[msg.sender] + UPGRADE_COOLDOWN, "Upgrade cooldown active");
        _lastUpgradeRequest[msg.sender] = block.timestamp;

        require(!_inTransaction, "Transaction in progress");
        require(msg.sender != address(0), "Invalid sender");
        require(members[msg.sender].registeredAt > 0, "Member not registered");
        require(_newPlanId > 0 && _newPlanId <= state.planCount, "Invalid plan ID");
        require(plans[_newPlanId].isActive, "Plan is not active");

        Member storage member = members[msg.sender];
        require(_newPlanId > member.planId, "Can only upgrade to higher plan");
        require(_newPlanId == member.planId + 1, "Cannot skip plans, must upgrade sequentially");

        uint256 priceDifference = plans[_newPlanId].price - plans[member.planId].price;
        require(priceDifference > 0, "Invalid price difference");
        
        // Safely transfer tokens with validation
        _safeTransferFrom(msg.sender, address(this), priceDifference);

        uint256 oldPlanId = member.planId;
        address upline = member.upline;

        // Update cycle info
        CycleInfo storage cycleInfo = planCycles[_newPlanId];
        unchecked { cycleInfo.membersInCurrentCycle++; }
        
        if (cycleInfo.membersInCurrentCycle >= plans[_newPlanId].membersPerCycle) {
            unchecked { 
                cycleInfo.currentCycle++;
                cycleInfo.membersInCurrentCycle = 0;
            }
            emit NewCycleStarted(_newPlanId, cycleInfo.currentCycle);
        }

        // Update member info
        member.cycleNumber = cycleInfo.currentCycle;
        member.planId = _newPlanId;

        // Notify upline if needed
        if (upline != address(0) && members[upline].planId < _newPlanId) {
            emit UplineNotified(upline, msg.sender, oldPlanId, _newPlanId);
        }

        // Distribute funds
        _distributeFunds(priceDifference, upline);

        // Update NFT metadata
        uint256 tokenId = tokenOfOwnerByIndex(msg.sender, 0);
        NFTImage storage tokenImage = tokenImages[tokenId];
        tokenImage.planId = _newPlanId;
        tokenImage.name = plans[_newPlanId].name;
        tokenImage.description = string(abi.encodePacked("Crypto Membership NFT - ", plans[_newPlanId].name, " Plan"));

        emit PlanUpgraded(msg.sender, oldPlanId, _newPlanId, cycleInfo.currentCycle);
        emit PlanUpgradeRequested(msg.sender, oldPlanId, _newPlanId);
    }

    // ===== MEMBER EXIT =====
    function exitMembership() external nonReentrant whenNotPaused onlyMember {
        Member storage member = members[msg.sender];
        
        // Calculate required membership time, accounting for paused periods
        uint256 requiredTime = member.registeredAt + 30 days;
        require(block.timestamp > requiredTime, "Exit unavailable before 30 days");
        
        uint256 planPrice = plans[member.planId].price;
        uint256 refundAmount = (planPrice * 30) / 100;
        
        require(state.fundBalance >= refundAmount, "Insufficient fund balance for refund");
        
        unchecked { state.fundBalance -= refundAmount; }
        
        uint256 tokenId = tokenOfOwnerByIndex(msg.sender, 0);
        delete tokenImages[tokenId];
        
        _burn(tokenId);
        delete members[msg.sender];
        
        _safeTransfer(msg.sender, refundAmount);
        
        emit MemberExited(msg.sender, refundAmount);
    }
    
    // ===== FINANCE MANAGEMENT =====
    function withdrawOwnerBalance(uint256 amount) external onlyOwner nonReentrant noReentrantTransfer {
        require(amount <= state.ownerBalance, "Insufficient owner balance");
        unchecked { state.ownerBalance -= amount; }
        _safeTransfer(owner(), amount);
    }

    function withdrawFeeSystemBalance(uint256 amount) external onlyOwner nonReentrant noReentrantTransfer {
        require(amount <= state.feeSystemBalance, "Insufficient fee balance");
        unchecked { state.feeSystemBalance -= amount; }
        _safeTransfer(owner(), amount);
    }

    function withdrawFundBalance(uint256 amount) external onlyOwner nonReentrant noReentrantTransfer {
        require(amount <= state.fundBalance, "Insufficient fund balance");
        unchecked { state.fundBalance -= amount; }
        _safeTransfer(owner(), amount);
    }

    // ===== BATCH WITHDRAWALS =====
    struct WithdrawalRequest {
        address recipient;
        uint256 amount;
        uint256 balanceType; // 0: owner, 1: fee, 2: fund
    }

    function batchWithdraw(WithdrawalRequest[] calldata requests) external onlyOwner nonReentrant noReentrantTransfer {
        require(requests.length > 0, "Empty request array");
        require(requests.length <= 20, "Too many requests");
        
        uint256 totalOwner;
        uint256 totalFee;
        uint256 totalFund;
        
        // Process each withdrawal in a single loop
        for (uint256 i = 0; i < requests.length;) {
            WithdrawalRequest calldata req = requests[i];
            
            require(req.recipient != address(0), "Invalid recipient");
            require(req.amount > 0, "Invalid amount");
            require(req.balanceType <= 2, "Invalid balance type");
            
            if (req.balanceType == 0) {
                require(req.amount <= state.ownerBalance, "Insufficient owner balance");
                unchecked { 
                    totalOwner += req.amount;
                    state.ownerBalance -= req.amount; 
                }
            } else if (req.balanceType == 1) {
                require(req.amount <= state.feeSystemBalance, "Insufficient fee balance");
                unchecked { 
                    totalFee += req.amount;
                    state.feeSystemBalance -= req.amount; 
                }
            } else {
                require(req.amount <= state.fundBalance, "Insufficient fund balance");
                unchecked { 
                    totalFund += req.amount;
                    state.fundBalance -= req.amount; 
                }
            }
            
            _safeTransfer(req.recipient, req.amount);
            
            unchecked { ++i; }
        }
        
        emit BatchWithdrawalProcessed(totalOwner, totalFee, totalFund);
    }
    
    // ===== INFO & QUERY FUNCTIONS =====
    function getPlanCycleInfo(uint256 _planId) external view returns (
        uint256 currentCycle, 
        uint256 membersInCurrentCycle, 
        uint256 membersPerCycle
    ) {
        require(_planId > 0 && _planId <= state.planCount, "Invalid plan ID");
        CycleInfo memory cycleInfo = planCycles[_planId];
        return (cycleInfo.currentCycle, cycleInfo.membersInCurrentCycle, plans[_planId].membersPerCycle);
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
            state.ownerBalance + state.feeSystemBalance + state.fundBalance + state.totalCommissionPaid,
            state.totalCommissionPaid,
            state.ownerBalance,
            state.feeSystemBalance,
            state.fundBalance
        );
    }
    
    function getContractStatus() external view returns (
        bool isPaused,
        uint256 totalBalance,
        uint256 memberCount,
        uint256 currentPlanCount,
        bool hasEmergencyRequest,
        uint256 emergencyTimeRemaining
    ) {
        uint256 timeRemaining = state.emergencyWithdrawRequestTime > 0 ? 
            state.emergencyWithdrawRequestTime + EMERGENCY_TIMELOCK - block.timestamp : 0;
        
        return (
            state.paused,
            usdtToken.balanceOf(address(this)),
            totalSupply(),
            state.planCount,
            state.emergencyWithdrawRequestTime > 0,
            timeRemaining
        );
    }
    
    // ===== CONTRACT CONFIGURATION =====
    function updateMembersPerCycle(uint256 _planId, uint256 _newMembersPerCycle) external onlyOwner {
        require(_planId > 0 && _planId <= state.planCount, "Invalid plan ID");
        require(_newMembersPerCycle == MAX_MEMBERS_PER_CYCLE, "Invalid members per cycle");
        plans[_planId].membersPerCycle = _newMembersPerCycle;
    }

    function setBaseURI(string calldata baseURI) external onlyOwner {
        require(bytes(baseURI).length > 0, "Base URI cannot be empty");
        _baseTokenURI = baseURI;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function setPlanStatus(uint256 _planId, bool _isActive) external onlyOwner {
        require(_planId > 0 && _planId <= state.planCount, "Invalid plan ID");
        plans[_planId].isActive = _isActive;
    }
    
    function setPriceFeed(address _priceFeed) external onlyOwner {
        require(_priceFeed != address(0), "Invalid price feed address");
        priceFeed = _priceFeed;
        emit PriceFeedUpdated(_priceFeed);
    }

    // ===== EMERGENCY FUNCTIONS =====
    function setPaused(bool _paused) external onlyOwner {
        state.paused = _paused;
        emit ContractPaused(_paused);
        emit ContractStatusUpdated(_paused, usdtToken.balanceOf(address(this)));
    }

    function requestEmergencyWithdraw() external onlyOwner {
        state.emergencyWithdrawRequestTime = block.timestamp;
        emit EmergencyWithdrawRequested(block.timestamp);
    }

    function emergencyWithdraw() external onlyOwner nonReentrant noReentrantTransfer {
        require(state.emergencyWithdrawRequestTime > 0, "No withdrawal requested");
        require(block.timestamp >= state.emergencyWithdrawRequestTime + EMERGENCY_TIMELOCK, "Timelock not expired");
        
        uint256 contractBalance = usdtToken.balanceOf(address(this));
        require(contractBalance > 0, "No funds available");
        
        emit EmergencyWithdrawInitiated(block.timestamp, contractBalance);
        
        // Reset timelock and balances
        state.emergencyWithdrawRequestTime = 0;
        state.ownerBalance = 0;
        state.feeSystemBalance = 0;
        state.fundBalance = 0;
        
        _safeTransfer(owner(), contractBalance);
        
        emit EmergencyWithdraw(owner(), contractBalance);
    }
    
    function restartAfterPause() external onlyOwner {
        require(state.paused, "Contract is not paused");
        state.paused = false;
        emit ContractPaused(false);
        emit ContractStatusUpdated(false, usdtToken.balanceOf(address(this)));
    }
    
    // ===== CONTRACT VALIDATION =====
    function validateContractBalance() public view returns (bool, uint256, uint256) {
        uint256 expectedBalance = state.ownerBalance + state.feeSystemBalance + state.fundBalance;
        uint256 actualBalance = usdtToken.balanceOf(address(this));
        return (actualBalance >= expectedBalance, expectedBalance, actualBalance);
    }

    // ===== NEW STATE VARIABLES =====
    mapping(address => bool) private _isReferralLoop;
    mapping(address => uint256) private _lastUpgradeRequest;
    uint256 private constant UPGRADE_COOLDOWN = 1 days;
    uint256 private constant MAX_REFERRAL_DEPTH = 10;

    // ===== NEW HELPER FUNCTIONS =====
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
}