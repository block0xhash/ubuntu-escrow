using System.Numerics;
using Nethereum.Web3;
using Nethereum.Web3.Accounts;
using Nethereum.ABI.FunctionEncoding.Attributes;
using Nethereum.Contracts;
using Newtonsoft.Json.Linq;
using Nethereum.RPC.Eth.DTOs;

namespace EscrowApp.Core;

public class EscrowManager
{
    private readonly Web3 _web3;
    private readonly string _contractAddress;
    private readonly string _abi;

    public EscrowManager(string rpcUrl, string privateKey, string contractAddress, string abiPath)
    {
        var account = new Account(privateKey);
        _web3 = new Web3(account, rpcUrl);
        _contractAddress = contractAddress;

        var json = File.ReadAllText(abiPath);
        var jobject = JObject.Parse(json);
        _abi = jobject["abi"]?.ToString() ?? throw new Exception("ABI not found in JSON");
    }

    public async Task<uint> CreateDealAsync(string sellerAddress, decimal amountEth)
    {
        var contractHandler = _web3.Eth.GetContractHandler(_contractAddress);
        var amountWei = Web3.Convert.ToWei(amountEth);

        var createDealInput = new CreateDealFunctionInput
        {
            Seller = sellerAddress,
            CollateralReq = 0,
            AmountToSend = amountWei
        };

        var receipt = await contractHandler.SendRequestAndWaitForReceiptAsync(createDealInput);
        
        if (receipt.Status.Value == 0) throw new Exception("Transaction Reverted.");

        // Decoding with the full Event DTO
        var decodedEvents = receipt.DecodeAllEvents<DealCreatedEventDTO>();
        
        if (decodedEvents == null || decodedEvents.Count == 0) 
            throw new Exception("DealCreated event not found. Check if the contract address is correct.");
        
        return (uint)decodedEvents[0].Event.DealId;
    }

    public async Task MarkShippedAsync(uint dealId)
    {
        var contractHandler = _web3.Eth.GetContractHandler(_contractAddress);
        var input = new MarkShippedFunctionInput { DealId = dealId };
        await contractHandler.SendRequestAndWaitForReceiptAsync(input);
    }

    public async Task ConfirmReceiptAsync(uint dealId)
    {
        var contractHandler = _web3.Eth.GetContractHandler(_contractAddress);
        var input = new ConfirmReceiptFunctionInput { DealId = dealId };
        await contractHandler.SendRequestAndWaitForReceiptAsync(input);
    }

    public async Task<string> GetStatusAsync(uint dealId)
    {
        var contractHandler = _web3.Eth.GetContractHandler(_contractAddress);
        var input = new DealsMappingInput { DealId = dealId };
        var deal = await contractHandler.QueryDeserializingToObjectAsync<DealsMappingInput, DealStruct>(input);
        
        return deal.Status switch {
            0 => "Created", 1 => "Funded", 2 => "Shipped", 3 => "Disputed",
            4 => "Resolved", 5 => "Released", 6 => "Refunded", _ => "Unknown"
        };
    }
}

// --- DTO CLASSES ---

[Function("createDeal", "uint256")]
public class CreateDealFunctionInput : FunctionMessage {
    [Parameter("address", "_seller", 1)] public string Seller { get; set; } = "";
    [Parameter("uint256", "_collateralReq", 2)] public BigInteger CollateralReq { get; set; }
}

[Function("markShipped")]
public class MarkShippedFunctionInput : FunctionMessage {
    [Parameter("uint256", "_dealId", 1)] public BigInteger DealId { get; set; }
}

[Function("confirmReceipt")]
public class ConfirmReceiptFunctionInput : FunctionMessage {
    [Parameter("uint256", "_dealId", 1)] public BigInteger DealId { get; set; }
}

[Function("deals", typeof(DealStruct))]
public class DealsMappingInput : FunctionMessage {
    [Parameter("uint256", "", 1)] public BigInteger DealId { get; set; }
}

[FunctionOutput]
public class DealStruct : IFunctionOutputDTO {
    [Parameter("address", "buyer", 1)] public string Buyer { get; set; } = "";
    [Parameter("address", "seller", 2)] public string Seller { get; set; } = "";
    [Parameter("uint256", "amount", 3)] public BigInteger Amount { get; set; }
    [Parameter("uint256", "collateralRequired", 4)] public BigInteger CollateralRequired { get; set; }
    [Parameter("uint256", "shippedTimestamp", 5)] public BigInteger ShippedTimestamp { get; set; }
    [Parameter("uint8", "status", 6)] public int Status { get; set; }
    [Parameter("bool", "sellerCollateralPosted", 7)] public bool SellerCollateralPosted { get; set; }
}

[Event("DealCreated")]
public class DealCreatedEventDTO : IEventDTO {
    [Parameter("uint256", "dealId", 1, true)] public BigInteger DealId { get; set; }
    [Parameter("address", "buyer", 2, false)] public string Buyer { get; set; } = "";
    [Parameter("address", "seller", 3, false)] public string Seller { get; set; } = "";
    [Parameter("uint256", "amount", 4, false)] public BigInteger Amount { get; set; }
}
