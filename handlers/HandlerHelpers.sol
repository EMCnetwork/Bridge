pragma solidity 0.6.4;

import "../interfaces/IERCHandler.sol";

/**
    @title Function used across handler contracts.
    @author ChainSafe Systems.
    @notice This contract is intended to be used with the Bridge contract.
 */
abstract contract HandlerHelpers is IERCHandler {
    address public _bridgeAddress;

    // resourceID => token contract address
    mapping (bytes32 => address) public _resourceIDToTokenContractAddress;

    // token contract address => resourceID
    mapping (address => bytes32) public _tokenContractAddressToResourceID;

    // token contract address => is whitelisted
    mapping (address => bool) public _contractWhitelist;

    // token contract address => is burnable
    mapping (address => bool) public _burnList;

    modifier onlyBridge() {
        _onlyBridge();
        _;
    }

    function _onlyBridge() private {
        require(msg.sender == _bridgeAddress, "sender must be bridge contract");
    }

    /**
        @notice First verifies {_resourceIDToContractAddress}[{resourceID}] and
        {_contractAddressToResourceID}[{contractAddress}] are not already set,
        then sets {_resourceIDToContractAddress} with {contractAddress},
        {_contractAddressToResourceID} with {resourceID},
        and {_contractWhitelist} to true for {contractAddress}.
        @param resourceID ResourceID to be used when making deposits.
        @param contractAddress Address of contract to be called when a deposit is made and a deposited is executed.
     */
    function setResource(bytes32 resourceID, address contractAddress) external override onlyBridge {

        _setResource(resourceID, contractAddress);
    }

    /**
        @notice First verifies {contractAddress} is whitelisted, then sets {_burnList}[{contractAddress}]
        to true.
        @param contractAddress Address of contract to be used when making or executing deposits.
     */
    function setBurnable(address contractAddress) external override onlyBridge{
        _setBurnable(contractAddress);
    }

    /**
        @notice Used to manually release funds from ERC safes.
        @param tokenAddress Address of token contract to release.
        @param recipient Address to release tokens to.
        @param amount Either the amount of ERC20 tokens to release.
     */
    function withdraw(address tokenAddress, address recipient, uint256 amount) external virtual override {}

    function _setResource(bytes32 resourceID, address contractAddress) internal {
        require(_resourceIDToTokenContractAddress[resourceID] == address(0), "Resource ID already set");
        require(_tokenContractAddressToResourceID[contractAddress] == bytes32(0), "Contract address already set");
        _resourceIDToTokenContractAddress[resourceID] = contractAddress;
        _tokenContractAddressToResourceID[contractAddress] = resourceID;

        _contractWhitelist[contractAddress] = true;
    }

    function _setBurnable(address contractAddress) internal {
        require(_contractWhitelist[contractAddress], "provided contract is not whitelisted");
        require(!_burnList[contractAddress], "Contract address already set as burnable");
        _burnList[contractAddress] = true;
    }
}
