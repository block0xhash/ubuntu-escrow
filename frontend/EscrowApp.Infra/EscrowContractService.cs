using System.Numerics;
using Nethereum.Web3;
using Nethereum.ABI.FunctionEncoding.Attributes;
using Nethereum.Contracts;

namespace EscrowApp.Infra;

public class EscrowContractService
{
    private readonly Web3 _web3;
    private readonly string _contractAddress;

    // ABI matching the deployed Escrow contract on GIWA Sepolia. Struct field order
    // must track Escrow.sol's Deal struct, including the trailing targetBuyer field.
    private const string ABI = @"[
        {'inputs':[{'internalType':'uint256','name':'','type':'uint256'}],'name':'deals','outputs':[{'internalType':'address','name':'buyer','type':'address'},{'internalType':'address','name':'seller','type':'address'},{'internalType':'uint256','name':'amount','type':'uint256'},{'internalType':'bool','name':'collateralRequired','type':'bool'},{'internalType':'uint256','name':'shippedTimestamp','type':'uint256'},{'internalType':'uint8','name':'status','type':'uint8'},{'internalType':'uint256','name':'collateralPosted','type':'uint256'},{'internalType':'address','name':'targetBuyer','type':'address'}],'stateMutability':'view','type':'function'},
        {'inputs':[],'name':'dealCounter','outputs':[{'internalType':'uint256','name':'','type':'uint256'}],'stateMutability':'view','type':'function'}
    ]";

    public EscrowContractService(string rpcUrl, string contractAddress)
    {
        _contractAddress = contractAddress;
        _web3 = new Web3(rpcUrl);
    }

    public async Task<BigInteger> GetDealCounterAsync()
    {
        var contract = _web3.Eth.GetContract(ABI, _contractAddress);
        var function = contract.GetFunction("dealCounter");
        return await function.CallAsync<BigInteger>();
    }

    public async Task<DealOnChainDto> GetDealAsync(BigInteger dealId)
    {
        var contract = _web3.Eth.GetContract(ABI, _contractAddress);
        var function = contract.GetFunction("deals");
        return await function.CallDeserializingToObjectAsync<DealOnChainDto>(dealId);
    }
}

[FunctionOutput]
public class DealOnChainDto : IFunctionOutputDTO
{
    [Parameter("address", "buyer", 1)]
    public string Buyer { get; set; } = string.Empty;

    [Parameter("address", "seller", 2)]
    public string Seller { get; set; } = string.Empty;

    [Parameter("uint256", "amount", 3)]
    public BigInteger Amount { get; set; }

    [Parameter("bool", "collateralRequired", 4)]
    public bool CollateralRequired { get; set; }

    [Parameter("uint256", "shippedTimestamp", 5)]
    public BigInteger ShippedTimestamp { get; set; }

    [Parameter("uint8", "status", 6)]
    public byte Status { get; set; }

    [Parameter("uint256", "collateralPosted", 7)]
    public BigInteger CollateralPosted { get; set; }

    [Parameter("address", "targetBuyer", 8)]
    public string TargetBuyer { get; set; } = string.Empty;
}
