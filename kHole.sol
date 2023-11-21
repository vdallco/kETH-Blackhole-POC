import "./kHoleLP.sol";

// Example arb trade:
// WETH holder (Wi) deposits 1.1 WETH, and is minted 1.1 kHoleLP token (entitles the LP token holder to [1.1 divided by TVL of the kHole] % of swap fee emissions
// rETH holder (Ri) swaps 1 rETH for 1.1 WETH (10% discount) and pays a 0.03333.. WETH fee (3.33..%), profiting 6.666..% or ~.07 ETH.
//  - kHole contract automatically deposits 1 rETH into kETHVault
// (Wi) claims all of the fee emissions (~0.033.. WETH) because no one else deposited tokens yet, so their LP position is 100%
// (Ri) unwraps ~1.07 WETH to ETH, nets 0.02 ETH, and stakes 1.05 ETH anywhere (RocketPool again for example)
// (Ri) repeats the cycle, this time with 1.05 rETH, and buys more discounted tokens to continue arb'ing
// (Wi) stakes their kHoleLP tokens in exchange for fee emissions on swaps and a share of half the minted kETH (kETHStakeDivisor=2)


contract kHole{
    modifier onlyOwner() {
        require(msg.sender == owner, "onlyOnwer");
        _;
    }

    struct TokenDeposit{
        uint256 id;
        uint256 amount;
        address oracleAddress;
    }

    address public kETHVault;
    address public bsnFarming;
    uint256 public feeDivisor;
    address public owner;

    kHoleLP public kHoleLPtoken;
    address[] public whitelistedTokens;
    address[] public depositedTokens;
    mapping(address => TokenDeposit) public deposits;
    mapping(address => uint256) public stakedLPTokens;
    uint256 depositIndex;
    address public WETH = 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6; // Goerli
    address public kETH = 0x509c0a85e5e23bAB829B441Ed5390452dEf827e4; // Goerli
    address public rETH = 0x178E141a0E3b34152f73Ff610437A7bf9B83267A; // Goerli
    
    uint256 public discount = 1000; // 1000 = 10%. Formula = amount*discount/10000
    uint256 public minFeeDivisor = 5; // Max Fee is 100/5 or 25%
    //address public feeRecipient;

    uint256 kETHStakeDivisor = 2; // 100/2 = 50% of kETH will be staked, and the rest set aside for kHoleLP stakers

    constructor(address _kETHVault, address _bsnFarming, uint256 _feeDivisor, address[] memory _whitelistedTokens) public {
        require(_feeDivisor >= minFeeDivisor, "feeDivisor is too low");
        kETHVault = _kETHVault;
        feeDivisor = _feeDivisor;
        kHoleLPtoken = new kHoleLP(address(this));
        whitelistedTokens = _whitelistedTokens;
        //feeRecipient = msg.sender;
        bsnFarming = _bsnFarming;
    }

    function _depositLST(address underlying, uint256 amount) internal returns (uint256) {
        // deposit(address _underlying,uint256 _amount,address _recipient,bool _sellForDETH)
        (bool success, bytes memory data) = kETHVault.call(abi.encodeWithSignature("deposit(address,uint256,address,bool)", underlying, amount, address(this), false));
        // Take the 3rd item of the above result (applicant or smart wallet). It's owner() is the LiquidStakingManager
        require(success, "failed to deposit LST to kETH vault");
        (uint256 share) = abi.decode(data, (uint256));
        return share;
    }

    function _stakeKETH(uint256 amount) internal {
        (bool success, ) = bsnFarming.call(abi.encodeWithSignature("deposit(uint256,uint256)", 0, amount));
        require(success, "failed to stake kETH");
    }

    function _approveToken(address token, address spender, uint256 amount) internal {
        ERC20(token).approve(spender, amount);
    }

    function swapLST(address liquidStakingToken, uint256 amountIn, address tokenOut, uint256 amountOut) external {
        require(liquidStakingToken == rETH, "unsupported liquid staking token"); // TO-DO: add || cbETH || stETJ etc
        uint256 blackholeBalance = ERC20(tokenOut).balanceOf(address(this));
        require(amountOut <= blackholeBalance, "not enough tokens in blackhole to fund swap");
        if(tokenOut == WETH){
            // WETH and LST's are 1:1, so don't bother with Oracle price lookups here
            uint256 discountAmount = amountIn * discount / 10000; // 10% of amountIn iif discount == 1000
            uint256 maxTokenOut = amountIn + discountAmount;
            require(amountOut <= maxTokenOut, "tokenOut too large");
            uint256 feeAmount = amountOut / feeDivisor;
            uint256 swapAmount = amountOut - feeAmount;
            ERC20(liquidStakingToken).transferFrom(msg.sender, address(this), amountIn);
            ERC20(tokenOut).transferFrom(address(this), msg.sender, swapAmount);
            //ERC20(tokenOut).transferFrom(address(this), feeRecipient, feeAmount);
            _approveToken(liquidStakingToken, kETHVault, amountIn);
            uint256 kETHMinted = _depositLST(liquidStakingToken,amountIn);
            uint256 stakeAmt = kETHMinted/kETHStakeDivisor;
            _approveToken(kETH, bsnFarming, stakeAmt);
            _stakeKETH(stakeAmt);
        }else{
            require(1==0, "unimplemented tokenOut");
        }
    }

    function claimShare() public view returns (uint256, uint256){
        uint256 wethBalance = ERC20(WETH).balanceOf(address(this));
        uint256 kethBalance = ERC20(kETH).balanceOf(address(this));

        uint256 stakedLPTokenAmount = stakedLPTokens[msg.sender];
        require(stakedLPTokenAmount>0, "msg.sender has no staked kHoleLP tokens");
        uint256 kHoleLPSupply = kHoleLPtoken.totalSupply();
        require(kHoleLPSupply>0,"no kHoleLP tokens have been staked");
        uint256 wethAllocation = (stakedLPTokenAmount * wethBalance) / kHoleLPSupply;

        uint256 kethAllocation = (stakedLPTokenAmount * kethBalance) / kHoleLPSupply;

        return (wethAllocation, kethAllocation);
        
    }

    function stakeLP(uint256 amount) external {
        kHoleLPtoken.transferFrom(msg.sender, address(this), amount);
        stakedLPTokens[msg.sender] = stakedLPTokens[msg.sender] + amount;
    }

    function claim() external {
        (uint256 wethClaim, uint256 kethClaim) = claimShare();
        ERC20(WETH).transferFrom(address(this), msg.sender, wethClaim);
        ERC20(kETH).transferFrom(address(this), msg.sender, kethClaim);
    }

    function whitelistToken(address token) external onlyOwner {
        bool isTokenWhitelisted = _isTokenWhitelisted(token);
        require(!isTokenWhitelisted, "token already whitelisted");
        whitelistedTokens.push(token);
    }

    function unwhitelistToken(address token) external onlyOwner {
        bool isTokenWhitelisted = _isTokenWhitelisted(token);
        require(isTokenWhitelisted, "token not whitelisted");
        for(uint256 x = 0; x<whitelistedTokens.length; x++){
            if(whitelistedTokens[x]!=token){
                delete whitelistedTokens[x];
            }
        }
    }

    function _mintLP(address recipient, uint256 ethAmount) internal {
        require(address(kHoleLPtoken) != address(0), "kHoleLPtoken not deployed");
        kHoleLPtoken.mint(recipient, ethAmount);
    }

    function _startMint(address recipient, address tokenAddress, uint256 amount, address oracleAddress) internal
    {
        if(tokenAddress == WETH){
            // WETH is 1:1 w/ ETH, no need for oracle lookups, just mint the LP tokens 1:1
            _mintLP(recipient, amount);
        }else{
            // TO-DO: call Oracle to get token/ETH price and mint 1:1 kHoleLP tokens to the recipient
            require(1==0, "unimplemented, only WETH deposits supported at the moment");
        }
    }

    function _isTokenWhitelisted(address token)  internal view returns (bool) {
        for(uint256 x=0; x<whitelistedTokens.length; x++){
            if(whitelistedTokens[x]==token){
                return true;
            }
        }
        return false;
    }

    function blackholeTokens(address tokenAddress, uint256 amount, address oracleAddress) external
    {
        uint256 sizeOfTokenContract;
        uint256 sizeOfOracleContract;
        assembly {
            sizeOfTokenContract := extcodesize(tokenAddress)
            sizeOfOracleContract := extcodesize(oracleAddress)
        }
        require(sizeOfTokenContract > 0, "blackhole token is invalid");
        require(sizeOfOracleContract > 0, "oracle is invalid");

        bool isTokenWhitelisted = _isTokenWhitelisted(tokenAddress);
        require(isTokenWhitelisted, "token not whitelisted");

        require(amount>0, "token amount must be non-zero");

        bool existingDeposit = false;
        bool existingToken = false;

        TokenDeposit storage deposit = deposits[tokenAddress];

        for(uint256 x;x<depositedTokens.length;x++){
            if(depositedTokens[x]==tokenAddress){
                existingToken = true;
                if(deposit.amount > 0){
                    require(deposit.oracleAddress == oracleAddress, "oracle does not match existing deposit");
                    existingDeposit = true;
                }
            }
        }

        if(existingDeposit){
            ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
            deposit.amount = deposit.amount + amount;

            deposits[tokenAddress] = deposit;
        }else{
            ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
            
            deposits[tokenAddress] = TokenDeposit(depositIndex, amount, oracleAddress);
            if(!existingToken){
                depositedTokens.push(tokenAddress);
            }
            depositIndex = depositIndex + 1;
        }

        _startMint(msg.sender, tokenAddress, amount, oracleAddress);
    }

    

}