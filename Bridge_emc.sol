pragma solidity 0.6.4;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./utils/Pausable.sol";
// import "./utils/SafeMath.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IDepositExecute.sol";
import "./interfaces/IBridge.sol";
import "./interfaces/IERCHandler.sol";
// import "./interfaces/IGenericHandler.sol";
import "./interfaces/IWEMC.sol"; 
/**
    @title Facilitates deposits, creation and votiing of deposit proposals, and deposit executions.
    @author ChainSafe Systems.
 */
contract Bridge is Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    uint8   public _chainID;
    uint256 public _relayerThreshold;
    uint256 public _totalRelayers;
    uint256 public _totalProposals;
    uint256 public _fee;
    uint256 public _expiry;
    address public erc20HandlerAddress;
    address public WEMC_ADDRESS; 

    enum Vote {No, Yes}

    enum ProposalStatus {Inactive, Active, Passed, Executed, Cancelled}

    struct Proposal {
        bytes32 _resourceID;
        bytes32 _dataHash;
        address[] _yesVotes;
        // address[] _noVotes;
        ProposalStatus _status;
        uint256 _proposedBlock;
    }

    // destinationChainID => number of deposits
    mapping(uint8 => uint64) public _depositCounts;
    // resourceID => handler address
    mapping(bytes32 => address) public _resourceIDToHandlerAddress;
    // depositNonce => destinationChainID => bytes
    mapping(uint64 => mapping(uint8 => bytes)) public _depositRecords;
    // destinationChainID + depositNonce => dataHash => Proposal
    mapping(uint72 => mapping(bytes32 => Proposal)) public _proposals;
    // destinationChainID + depositNonce => dataHash => relayerAddress => bool
    mapping(uint72 => mapping(bytes32 => mapping(address => bool))) public _hasVotedOnProposal;
    
    mapping(address => bool) isRelayerAdded;

    event RelayerThresholdChanged(uint indexed newThreshold);
    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event Deposit(
        uint8   indexed destinationChainID,
        bytes32 indexed resourceID,
        uint64  indexed depositNonce
       
    );
    event ProposalEvent(
        uint8           indexed originChainID,
        uint64          indexed depositNonce,
        ProposalStatus  indexed status,
        bytes32 resourceID,
        bytes32 dataHash
    );

    event ProposalVote(
        uint8   indexed originChainID,
        uint64  indexed depositNonce,
        ProposalStatus indexed status,
        bytes32 resourceID
    );

    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    modifier onlyAdminOrRelayer() {
        _onlyAdminOrRelayer();
        _;
    }

    modifier onlyRelayers() {
        _onlyRelayers();
        _;
    }

    function grantRole(bytes32 role, address account) public override {
        super.grantRole(role, account);
        if (role == RELAYER_ROLE && !isRelayerAdded[account]) {
            isRelayerAdded[account] = true;
            _totalRelayers++;
        }
    }
    function revokeRole(bytes32 role, address account) public override {
        super.revokeRole(role, account);
        if (role == RELAYER_ROLE && isRelayerAdded[account]) {
            isRelayerAdded[account] = false;
            if (_totalRelayers > 0) {
                _totalRelayers--;
            }
        }
    }
    function renounceRole(bytes32 role, address account) public override {
        super.renounceRole(role, account);
        if (role == RELAYER_ROLE && isRelayerAdded[account]) {
            isRelayerAdded[account] = false;
            if (_totalRelayers > 0) {
                _totalRelayers--;
            }
        }
    }

    function _onlyAdminOrRelayer() private {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(RELAYER_ROLE, msg.sender),
            "sender is not relayer or admin");
    }

    function _onlyAdmin() private {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "sender doesn't have admin role");
    }

    function _onlyRelayers() private {
        require(hasRole(RELAYER_ROLE, msg.sender), "sender doesn't have relayer role");
    }
   
    /**
        @notice Initializes Bridge, creates and grants {msg.sender} the admin role,
        creates and grants {initialRelayers} the relayer role.
        @param chainID ID of chain the Bridge contract exists on.
        @param initialRelayers Addresses that should be initially granted the relayer role.
        @param initialRelayerThreshold Number of votes needed for a deposit proposal to be considered passed.
     */
    constructor (uint8 chainID, address[] memory initialRelayers, uint256 initialRelayerThreshold, uint256 fee, uint256 expiry,address wemcAddress) public {
        require(wemcAddress != address(0), "Invalid address: zero address");
        _chainID = chainID;
        _relayerThreshold = initialRelayerThreshold;
        _fee = fee;
        _expiry = expiry;
        WEMC_ADDRESS = wemcAddress;
        // grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setRoleAdmin(RELAYER_ROLE, DEFAULT_ADMIN_ROLE);
        uint256 initialRelayerCount = initialRelayers.length;
        for (uint i; i < initialRelayerCount; i++) {
            require(!isRelayerAdded[initialRelayers[i]], "Duplicate relayer address in initialRelayers");
            isRelayerAdded[initialRelayers[i]] = true;
            if(!hasRole(RELAYER_ROLE, initialRelayers[i])){
                grantRole(RELAYER_ROLE, initialRelayers[i]);

             }
           
        }

    }

    /**
        @notice Returns true if {relayer} has the relayer role.
        @param relayer Address to check.
     */
    function isRelayer(address relayer) external view returns (bool) {
        return hasRole(RELAYER_ROLE, relayer);
    }

    /**
        @notice Removes admin role from {msg.sender} and grants it to {newAdmin}.
        @notice Only callable by an address that currently has the admin role.
        @param newAdmin Address that admin role will be granted to.
     */
    function renounceAdmin(address newAdmin) external  {
        require(!hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "newAdmin already has admin role");
        grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
        @notice Pauses deposits, proposal creation and voting, and deposit executions.
        @notice Only callable by an address that currently has the admin role.
     */
    function adminPauseTransfers() external onlyAdmin {
        _pause();
    }

    /**
        @notice Unpauses deposits, proposal creation and voting, and deposit executions.
        @notice Only callable by an address that currently has the admin role.
     */
    function adminUnpauseTransfers() external onlyAdmin {
        _unpause();
    }
    function setHandlerAddress(address _handlerAddress) external onlyAdmin {
        require(_handlerAddress != address(0), "Invalid address: zero address");
        erc20HandlerAddress = _handlerAddress;
    }
    /**
        @notice Modifies the number of votes required for a proposal to be considered passed.
        @notice Only callable by an address that currently has the admin role.
        @param newThreshold Value {_relayerThreshold} will be changed to.
        @notice Emits {RelayerThresholdChanged} event.
     */
    function adminChangeRelayerThreshold(uint newThreshold) external onlyAdmin {
        require(newThreshold >= 1, "Threshold must be at least 1");
        _relayerThreshold = newThreshold;
        emit RelayerThresholdChanged(newThreshold);
    }

    /**
        @notice Grants {relayerAddress} the relayer role and increases {_totalRelayer} count.
        @notice Only callable by an address that currently has the admin role.
        @param relayerAddress Address of relayer to be added.
        @notice Emits {RelayerAdded} event.
     */
    function adminAddRelayer(address relayerAddress) external  {
        require(!hasRole(RELAYER_ROLE, relayerAddress), "addr already has relayer role!");
        grantRole(RELAYER_ROLE, relayerAddress);
        emit RelayerAdded(relayerAddress);
    }

    /**
        @notice Removes relayer role for {relayerAddress} and decreases {_totalRelayer} count.
        @notice Only callable by an address that currently has the admin role.
        @param relayerAddress Address of relayer to be removed.
        @notice Emits {RelayerRemoved} event.
     */
    function adminRemoveRelayer(address relayerAddress) external {
        require(hasRole(RELAYER_ROLE, relayerAddress), "addr doesn't have relayer role!");
        revokeRole(RELAYER_ROLE, relayerAddress);
        require(_totalRelayers > 0, "No relayers to remove");
        emit RelayerRemoved(relayerAddress);
    }

    /**
        @notice Sets a new resource for handler contracts that use the IERCHandler interface,
        and maps the {handlerAddress} to {resourceID} in {_resourceIDToHandlerAddress}.
        @notice Only callable by an address that currently has the admin role.
        @param handlerAddress Address of handler resource will be set for.
        @param resourceID ResourceID to be used when making deposits.
        @param tokenAddress Address of contract to be called when a deposit is made and a deposited is executed.
     */
    function adminSetResource(address handlerAddress, bytes32 resourceID, address tokenAddress) external onlyAdmin {
        require(_resourceIDToHandlerAddress[resourceID] == address(0), "Resource ID already set");
        _resourceIDToHandlerAddress[resourceID] = handlerAddress;
        IERCHandler handler = IERCHandler(handlerAddress);
        handler.setResource(resourceID, tokenAddress);
    }

    /**
        @notice Sets a resource as burnable for handler contracts that use the IERCHandler interface.
        @notice Only callable by an address that currently has the admin role.
        @param handlerAddress Address of handler resource will be set for.
        @param tokenAddress Address of contract to be called when a deposit is made and a deposited is executed.
     */
    function adminSetBurnable(address handlerAddress, address tokenAddress) external onlyAdmin {
        IERCHandler handler = IERCHandler(handlerAddress);
        handler.setBurnable(tokenAddress);
    }

    /**
        @notice Returns a proposal.
        @param originChainID Chain ID deposit originated from.
        @param depositNonce ID of proposal generated by proposal's origin Bridge contract.
        @param dataHash Hash of data to be provided when deposit proposal is executed.
        @return Proposal which consists of:
        - _dataHash Hash of data to be provided when deposit proposal is executed.
        - _yesVotes Number of votes in favor of proposal.
        - _status Current status of proposal.
     */
    function getProposal(uint8 originChainID, uint64 depositNonce, bytes32 dataHash) external view returns (Proposal memory) {
        uint72 nonceAndID = (uint72(depositNonce) << 8) | uint72(originChainID);
        return _proposals[nonceAndID][dataHash];
    }

    /**
        @notice Changes deposit fee.
        @notice Only callable by admin.
        @param newFee Value {_fee} will be updated to.
     */
    function adminChangeFee(uint newFee) external onlyAdmin {
        require(newFee > 0, "Fee must be greater than zero");
        require(_fee != newFee, "Current fee is equal to new fee");
        _fee = newFee;
    }

    /**
        @notice Used to manually withdraw funds from ERC safes.
        @param handlerAddress Address of handler to withdraw from.
        @param tokenAddress Address of token to withdraw.
        @param recipient Address to withdraw tokens to.
        @param amount Either the amount of ERC20 tokens to withdraw.
     */
    function adminWithdraw(
        address handlerAddress,
        address tokenAddress,
        address recipient,
        uint256 amount
    ) external onlyAdmin {
        IERCHandler handler = IERCHandler(handlerAddress);
        handler.withdraw(tokenAddress, recipient, amount);
    }

   
   
    
    /**
        @notice Initiates a transfer using a specified handler contract.
        @notice Only callable when Bridge is not paused.
        @param destinationChainID ID of chain deposit will be bridged to.
        @param resourceID ResourceID used to find address of handler to be used for deposit.
        @param amount Additional data to be passed to specified handler.
        @notice Emits {Deposit} event.
     */
    function deposit(uint8 destinationChainID, bytes32 resourceID, uint256 amount) external payable whenNotPaused {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
       
        if (chainId != 6678 ){
            require(destinationChainID == 2, "destinationChainID supplied");

        } 
        require(msg.value >= _fee, "Incorrect fee supplied");
        if ((chainId == 6678 && resourceID == 0x0000000000000000000000000000000000000000000000000000000000000002) ||
        (chainId != 6678 && resourceID == 0x0000000000000000000000000000000000000000000000000000000000000000)) {
            uint256 emcAmount = msg.value.sub(_fee);
           
            IWEMC(WEMC_ADDRESS).deposit{value: emcAmount}();
            IERC20(WEMC_ADDRESS).safeApprove(erc20HandlerAddress, emcAmount);

            
            bytes memory data = abi.encodePacked(
                bytes32(emcAmount),         
                bytes32(uint256(20)),        
                abi.encodePacked(msg.sender) 
            );

           
            address handler = _resourceIDToHandlerAddress[resourceID];
            require(handler != address(0), "resourceID not mapped to handler");
            uint64 depositNonce = ++_depositCounts[destinationChainID];
            _depositRecords[depositNonce][destinationChainID] = data;

            IDepositExecute depositHandler = IDepositExecute(handler);
            depositHandler.deposit(resourceID, destinationChainID, depositNonce, address(this), data);

            emit Deposit(destinationChainID, resourceID, depositNonce);

        }else{
            address handler = _resourceIDToHandlerAddress[resourceID];
            require(handler != address(0), "resourceID not mapped to handler");
            bytes memory data = abi.encodePacked(
                bytes32(amount), // Deposit Amount
                bytes32(uint256(20)), // len(recipientAddress)
                abi.encodePacked(msg.sender) // recipientAddress
            );

            uint64 depositNonce = ++_depositCounts[destinationChainID];
            _depositRecords[depositNonce][destinationChainID] = data;

            IDepositExecute depositHandler = IDepositExecute(handler);
            depositHandler.deposit(resourceID, destinationChainID, depositNonce, msg.sender, data);

            emit Deposit(destinationChainID, resourceID, depositNonce);

        }
       
    }

    /**
        @notice When called, {msg.sender} will be marked as voting in favor of proposal.
        @notice Only callable by relayers when Bridge is not paused.
        @param chainID ID of chain deposit originated from.
        @param depositNonce ID of deposited generated by origin Bridge contract.
        @param dataHash Hash of data provided when deposit was made.
        @notice Proposal must not have already been passed or executed.
        @notice {msg.sender} must not have already voted on proposal.
        @notice Emits {ProposalEvent} event with status indicating the proposal status.
        @notice Emits {ProposalVote} event.
     */
    function voteProposal(uint8 chainID, uint64 depositNonce, bytes32 resourceID, bytes32 dataHash) external onlyRelayers whenNotPaused {

        uint72 nonceAndID = (uint72(depositNonce) << 8) | uint72(chainID);
        Proposal storage proposal = _proposals[nonceAndID][dataHash];

        require(_resourceIDToHandlerAddress[resourceID] != address(0), "no handler for resourceID");
        require(proposal._status == ProposalStatus.Inactive || proposal._status == ProposalStatus.Active,"proposal already passed/executed/cancelled");
        require(!_hasVotedOnProposal[nonceAndID][dataHash][msg.sender], "relayer already voted");

        if (uint(proposal._status) == 0) {
            ++_totalProposals;
            _proposals[nonceAndID][dataHash] = Proposal({
                _resourceID : resourceID,
                _dataHash : dataHash,
                _yesVotes : new address[](1),
                // _noVotes : new address[](0),
                _status : ProposalStatus.Active,
                _proposedBlock : block.number
                });

            proposal._yesVotes[0] = msg.sender;
            emit ProposalEvent(chainID, depositNonce, ProposalStatus.Active, resourceID, dataHash);
        } else {
            if (block.number.sub(proposal._proposedBlock) > _expiry) {
                // if the number of blocks that has passed since this proposal was
                // submitted exceeds the expiry threshold set, cancel the proposal
                proposal._status = ProposalStatus.Cancelled;
                emit ProposalEvent(chainID, depositNonce, ProposalStatus.Cancelled, resourceID, dataHash);
            } else {
                require(dataHash == proposal._dataHash, "datahash mismatch");
                proposal._yesVotes.push(msg.sender);


            }

        }
        if (proposal._status != ProposalStatus.Cancelled) {
            _hasVotedOnProposal[nonceAndID][dataHash][msg.sender] = true;
            emit ProposalVote(chainID, depositNonce, proposal._status, resourceID);

            // If _depositThreshold is set to 1, then auto finalize
            // or if _relayerThreshold has been exceeded
            if (_relayerThreshold <= 1 || proposal._yesVotes.length >= _relayerThreshold) {
                proposal._status = ProposalStatus.Passed;

                emit ProposalEvent(chainID, depositNonce, ProposalStatus.Passed, resourceID, dataHash);
            }
        }

    }

    /**
        @notice Cancels a deposit proposal that is either expired or still pending.
        @notice Callable by relayers or the admin even if the Bridge is paused.
        @param chainID ID of the chain where the deposit originated.
        @param depositNonce ID generated by the origin Bridge contract for the deposit.
        @param dataHash Hash of the original data provided when the deposit was made.
        @notice Proposal must be past the expiry threshold to be cancelled.
        @notice Emits {ProposalEvent} event with status {Cancelled}.
    */
    function cancelProposal(uint8 chainID, uint64 depositNonce, bytes32 dataHash) public onlyAdminOrRelayer {
        uint72 nonceAndID = (uint72(depositNonce) << 8) | uint72(chainID);
        Proposal storage proposal = _proposals[nonceAndID][dataHash];

        require(proposal._status != ProposalStatus.Cancelled, "Proposal already cancelled");
        require(proposal._status != ProposalStatus.Executed, "Proposal already executed");
        require(block.number.sub(proposal._proposedBlock) > _expiry, "Proposal not at expiry threshold");

        proposal._status = ProposalStatus.Cancelled;
        emit ProposalEvent(chainID, depositNonce, ProposalStatus.Cancelled, proposal._resourceID, proposal._dataHash);

    }

    /**
        @notice Executes a deposit proposal that is considered passed using a specified handler contract.
        @notice Only callable by relayers when Bridge is not paused.
        @param chainID ID of chain deposit originated from.
        @param resourceID ResourceID to be used when making deposits.
        @param depositNonce ID of deposited generated by origin Bridge contract.
        @param data Data originally provided when deposit was made.
        @notice Proposal must have Passed status.
        @notice Hash of {data} must equal proposal's {dataHash}.
        @notice Emits {ProposalEvent} event with status {Executed}.
     */
    function executeProposal(uint8 chainID, uint64 depositNonce, bytes calldata data, bytes32 resourceID) external onlyRelayers whenNotPaused {
        address handler = _resourceIDToHandlerAddress[resourceID];
        uint72 nonceAndID = (uint72(depositNonce) << 8) | uint72(chainID);
        bytes32 dataHash = keccak256(abi.encodePacked(handler, data));
        Proposal storage proposal = _proposals[nonceAndID][dataHash];

        require(proposal._status == ProposalStatus.Passed, "proposal is not in a valid state for execution");

        require(dataHash == proposal._dataHash, "data doesn't match datahash");
        require(block.number.sub(proposal._proposedBlock) <= _expiry, "Proposal has expired");

        proposal._status = ProposalStatus.Executed;

        IDepositExecute depositHandler = IDepositExecute(_resourceIDToHandlerAddress[proposal._resourceID]);
        depositHandler.executeProposal(proposal._resourceID, data);

        emit ProposalEvent(chainID, depositNonce, proposal._status, proposal._resourceID, proposal._dataHash);
    }

    /**
        @notice Transfers emc in the contract to the specified addresses. The parameters addrs and amounts are mapped 1-1.
        This means that the address at index 0 for addrs will receive the amount (in WEI) from amounts at index 0.
        @param addrs Array of addresses to transfer {amounts} to.
        @param amounts Array of amounts to transfer to {addrs}.
     */
    function transferFunds(address payable[] calldata addrs, uint[] calldata amounts) external onlyAdmin {
        require(addrs.length == amounts.length,"addrs and amounts len mismatch");
        uint256 addrCount = addrs.length;
        for (uint i = 0; i < addrCount; i++) {
            // addrs[i].transfer(amounts[i]);
            Address.sendValue(payable(addrs[i]), amounts[i]);
        }
    }

}
