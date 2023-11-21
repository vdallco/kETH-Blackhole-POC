import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract kHoleLP is ERC20 {
    address public owner;

    constructor(address _owner) ERC20("kHoleLP", "kHLP") {
        owner = _owner;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "onlyOwner");
        _mint(to, amount);
    }
}