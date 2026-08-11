using System.Numerics;
using Nethereum.ABI.FunctionEncoding.Attributes;
using Nethereum.Contracts;
using Nethereum.Web3;

namespace GswapApp.Web.Services;

/// <summary>
/// Read-only on-chain access (via server-side RPC, no wallet needed) plus calldata
/// encoding for the transactions the Razor pages hand off to MetaMask through
/// WalletStateService's JS-interop send flow - mirrors the EscrowContractService /
/// Market.razor split in EscrowApp.Web: Nethereum here is only ever used to talk to the
/// RPC or to encode calldata offline, never to hold a key or sign anything.
/// </summary>
public class GswapContractService
{
    private const string RouterAbi = @"[
        {'name':'getAmountsOut','type':'function','stateMutability':'view','inputs':[{'name':'amountIn','type':'uint256'},{'name':'path','type':'address[]'}],'outputs':[{'name':'amounts','type':'uint256[]'}]},
        {'name':'getAmountsIn','type':'function','stateMutability':'view','inputs':[{'name':'amountOut','type':'uint256'},{'name':'path','type':'address[]'}],'outputs':[{'name':'amounts','type':'uint256[]'}]},
        {'name':'addLiquidity','type':'function','stateMutability':'nonpayable','inputs':[{'name':'tokenA','type':'address'},{'name':'tokenB','type':'address'},{'name':'amountADesired','type':'uint256'},{'name':'amountBDesired','type':'uint256'},{'name':'amountAMin','type':'uint256'},{'name':'amountBMin','type':'uint256'},{'name':'to','type':'address'},{'name':'deadline','type':'uint256'}],'outputs':[]},
        {'name':'addLiquidityETH','type':'function','stateMutability':'payable','inputs':[{'name':'token','type':'address'},{'name':'amountTokenDesired','type':'uint256'},{'name':'amountTokenMin','type':'uint256'},{'name':'amountETHMin','type':'uint256'},{'name':'to','type':'address'},{'name':'deadline','type':'uint256'}],'outputs':[]},
        {'name':'removeLiquidity','type':'function','stateMutability':'nonpayable','inputs':[{'name':'tokenA','type':'address'},{'name':'tokenB','type':'address'},{'name':'liquidity','type':'uint256'},{'name':'amountAMin','type':'uint256'},{'name':'amountBMin','type':'uint256'},{'name':'to','type':'address'},{'name':'deadline','type':'uint256'}],'outputs':[]},
        {'name':'removeLiquidityETH','type':'function','stateMutability':'nonpayable','inputs':[{'name':'token','type':'address'},{'name':'liquidity','type':'uint256'},{'name':'amountTokenMin','type':'uint256'},{'name':'amountETHMin','type':'uint256'},{'name':'to','type':'address'},{'name':'deadline','type':'uint256'}],'outputs':[]},
        {'name':'swapExactTokensForTokensSupportingFeeOnTransferTokens','type':'function','stateMutability':'nonpayable','inputs':[{'name':'amountIn','type':'uint256'},{'name':'amountOutMin','type':'uint256'},{'name':'path','type':'address[]'},{'name':'to','type':'address'},{'name':'deadline','type':'uint256'}],'outputs':[]},
        {'name':'swapExactETHForTokensSupportingFeeOnTransferTokens','type':'function','stateMutability':'payable','inputs':[{'name':'amountOutMin','type':'uint256'},{'name':'path','type':'address[]'},{'name':'to','type':'address'},{'name':'deadline','type':'uint256'}],'outputs':[]},
        {'name':'swapExactTokensForETHSupportingFeeOnTransferTokens','type':'function','stateMutability':'nonpayable','inputs':[{'name':'amountIn','type':'uint256'},{'name':'amountOutMin','type':'uint256'},{'name':'path','type':'address[]'},{'name':'to','type':'address'},{'name':'deadline','type':'uint256'}],'outputs':[]}
    ]";

    private const string FactoryAbi = @"[
        {'name':'getPair','type':'function','stateMutability':'view','inputs':[{'name':'tokenA','type':'address'},{'name':'tokenB','type':'address'}],'outputs':[{'name':'pair','type':'address'}]},
        {'name':'allPairsLength','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'uint256'}]},
        {'name':'allPairs','type':'function','stateMutability':'view','inputs':[{'name':'','type':'uint256'}],'outputs':[{'name':'pair','type':'address'}]}
    ]";

    private const string PairAbi = @"[
        {'name':'getReserves','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'reserve0','type':'uint112'},{'name':'reserve1','type':'uint112'},{'name':'blockTimestampLast','type':'uint32'}]},
        {'name':'token0','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'address'}]},
        {'name':'token1','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'address'}]},
        {'name':'balanceOf','type':'function','stateMutability':'view','inputs':[{'name':'owner','type':'address'}],'outputs':[{'name':'','type':'uint256'}]},
        {'name':'totalSupply','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'uint256'}]}
    ]";

    private const string Erc20Abi = @"[
        {'name':'balanceOf','type':'function','stateMutability':'view','inputs':[{'name':'owner','type':'address'}],'outputs':[{'name':'','type':'uint256'}]},
        {'name':'allowance','type':'function','stateMutability':'view','inputs':[{'name':'owner','type':'address'},{'name':'spender','type':'address'}],'outputs':[{'name':'','type':'uint256'}]},
        {'name':'approve','type':'function','stateMutability':'nonpayable','inputs':[{'name':'spender','type':'address'},{'name':'amount','type':'uint256'}],'outputs':[{'name':'','type':'bool'}]},
        {'name':'decimals','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'uint8'}]},
        {'name':'symbol','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'string'}]},
        {'name':'name','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'string'}]}
    ]";

    // Speculative probe, not a real standard: GDOG (and anything shaped like it) taxes
    // buys/sells at the token level via its own transfer hook, which GswapRouter's
    // getAmountsOut has no visibility into - it only sees pair reserves. Calling this
    // and treating failure as "0 bps" lets the frontend correct its quotes for any
    // token that happens to expose the same view function GDOGToken does, without
    // hardcoding "if address == GDOG".
    private const string TaxProbeAbi = @"[
        {'name':'currentTaxBps','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'uint256'}]}
    ]";

    private const string LockerAbi = @"[
        {'name':'lockTokens','type':'function','stateMutability':'nonpayable','inputs':[{'name':'token','type':'address'},{'name':'amount','type':'uint256'},{'name':'unlockTime','type':'uint256'}],'outputs':[{'name':'lockId','type':'uint256'}]},
        {'name':'withdraw','type':'function','stateMutability':'nonpayable','inputs':[{'name':'lockId','type':'uint256'}],'outputs':[]},
        {'name':'locks','type':'function','stateMutability':'view','inputs':[{'name':'','type':'uint256'}],'outputs':[{'name':'token','type':'address'},{'name':'owner','type':'address'},{'name':'amount','type':'uint256'},{'name':'unlockTime','type':'uint256'},{'name':'withdrawn','type':'bool'}]},
        {'name':'getLocksByOwner','type':'function','stateMutability':'view','inputs':[{'name':'owner','type':'address'}],'outputs':[{'name':'','type':'uint256[]'}]}
    ]";

    private readonly GswapSettings _settings;

    public GswapContractService(Microsoft.Extensions.Options.IOptions<GswapSettings> settings)
    {
        _settings = settings.Value;
    }

    private Web3 Rpc() => new(_settings.RpcUrl);

    // ---------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------

    public async Task<List<BigInteger>> GetAmountsOutAsync(BigInteger amountIn, IEnumerable<string> path)
    {
        var contract = Rpc().Eth.GetContract(RouterAbi, _settings.RouterAddress);
        var function = contract.GetFunction("getAmountsOut");
        return await function.CallAsync<List<BigInteger>>(amountIn, path.ToArray());
    }

    public async Task<BigInteger> GetBalanceAsync(string tokenAddress, string owner)
    {
        if (string.IsNullOrEmpty(tokenAddress))
        {
            return await Rpc().Eth.GetBalance.SendRequestAsync(owner);
        }

        var contract = Rpc().Eth.GetContract(Erc20Abi, tokenAddress);
        return await contract.GetFunction("balanceOf").CallAsync<BigInteger>(owner);
    }

    public async Task<BigInteger> GetAllowanceAsync(string tokenAddress, string owner, string spender)
    {
        var contract = Rpc().Eth.GetContract(Erc20Abi, tokenAddress);
        return await contract.GetFunction("allowance").CallAsync<BigInteger>(owner, spender);
    }

    /// <summary>
    /// Current buy/sell tax in bps for a GDOG-shaped token, or 0 for native ETH, plain
    /// ERC20s, or anything the call reverts against. Used to correct quotes for tokens
    /// the AMM's own math can't see the tax on - see TaxProbeAbi.
    /// </summary>
    public async Task<BigInteger> TryGetTaxBpsAsync(string tokenAddress)
    {
        if (string.IsNullOrEmpty(tokenAddress)) return 0;
        try
        {
            var contract = Rpc().Eth.GetContract(TaxProbeAbi, tokenAddress);
            return await contract.GetFunction("currentTaxBps").CallAsync<BigInteger>();
        }
        catch
        {
            return 0;
        }
    }

    /// <summary>
    /// Resolves an arbitrary ERC20 by reading symbol/name/decimals directly from the
    /// contract - lets the token picker accept "any ERC20", same as Uniswap's "paste an
    /// address" flow, instead of being limited to appsettings.json's curated list.
    /// Throws if the address isn't a contract or doesn't implement the ERC20 read surface.
    /// </summary>
    public async Task<TokenInfo> GetErc20InfoAsync(string tokenAddress)
    {
        var contract = Rpc().Eth.GetContract(Erc20Abi, tokenAddress);
        var symbol = await contract.GetFunction("symbol").CallAsync<string>();
        var name = await contract.GetFunction("name").CallAsync<string>();
        var decimals = await contract.GetFunction("decimals").CallAsync<byte>();

        return new TokenInfo
        {
            Symbol = symbol,
            Name = name,
            Address = tokenAddress,
            Decimals = decimals,
        };
    }

    public async Task<string> GetPairAsync(string tokenA, string tokenB)
    {
        var contract = Rpc().Eth.GetContract(FactoryAbi, _settings.FactoryAddress);
        return await contract.GetFunction("getPair").CallAsync<string>(tokenA, tokenB);
    }

    public async Task<BigInteger> GetAllPairsLengthAsync()
    {
        var contract = Rpc().Eth.GetContract(FactoryAbi, _settings.FactoryAddress);
        return await contract.GetFunction("allPairsLength").CallAsync<BigInteger>();
    }

    public async Task<string> GetAllPairAtAsync(BigInteger index)
    {
        var contract = Rpc().Eth.GetContract(FactoryAbi, _settings.FactoryAddress);
        return await contract.GetFunction("allPairs").CallAsync<string>(index);
    }

    public async Task<PairReservesDto> GetReservesAsync(string pairAddress)
    {
        var contract = Rpc().Eth.GetContract(PairAbi, pairAddress);
        var reserves = await contract.GetFunction("getReserves").CallDeserializingToObjectAsync<PairReservesDto>();
        reserves.Token0 = await contract.GetFunction("token0").CallAsync<string>();
        reserves.Token1 = await contract.GetFunction("token1").CallAsync<string>();
        return reserves;
    }

    public async Task<BigInteger> GetPairTotalSupplyAsync(string pairAddress)
    {
        var contract = Rpc().Eth.GetContract(PairAbi, pairAddress);
        return await contract.GetFunction("totalSupply").CallAsync<BigInteger>();
    }

    public async Task<BigInteger> GetLpBalanceAsync(string pairAddress, string owner)
    {
        var contract = Rpc().Eth.GetContract(PairAbi, pairAddress);
        return await contract.GetFunction("balanceOf").CallAsync<BigInteger>(owner);
    }

    public async Task<List<BigInteger>> GetLocksByOwnerAsync(string owner)
    {
        var contract = Rpc().Eth.GetContract(LockerAbi, _settings.LockerAddress);
        return await contract.GetFunction("getLocksByOwner").CallAsync<List<BigInteger>>(owner);
    }

    public async Task<LockDto> GetLockAsync(BigInteger lockId)
    {
        var contract = Rpc().Eth.GetContract(LockerAbi, _settings.LockerAddress);
        return await contract.GetFunction("locks").CallDeserializingToObjectAsync<LockDto>(lockId);
    }

    // ---------------------------------------------------------------------
    // Calldata builders - pure offline ABI encoding, no RPC involved. The Razor pages
    // pass the resulting hex string to WalletStateService's eth_sendTransaction flow.
    // ---------------------------------------------------------------------

    public string EncodeApprove(string tokenAddress, string spender, BigInteger amount)
    {
        var contract = new Web3().Eth.GetContract(Erc20Abi, tokenAddress);
        return contract.GetFunction("approve").GetData(spender, amount);
    }

    public string EncodeAddLiquidity(
        string tokenA, string tokenB, BigInteger amountADesired, BigInteger amountBDesired,
        BigInteger amountAMin, BigInteger amountBMin, string to, BigInteger deadline)
    {
        var contract = new Web3().Eth.GetContract(RouterAbi, _settings.RouterAddress);
        return contract.GetFunction("addLiquidity")
            .GetData(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline);
    }

    public string EncodeAddLiquidityEth(
        string token, BigInteger amountTokenDesired, BigInteger amountTokenMin, BigInteger amountEthMin,
        string to, BigInteger deadline)
    {
        var contract = new Web3().Eth.GetContract(RouterAbi, _settings.RouterAddress);
        return contract.GetFunction("addLiquidityETH")
            .GetData(token, amountTokenDesired, amountTokenMin, amountEthMin, to, deadline);
    }

    public string EncodeRemoveLiquidity(
        string tokenA, string tokenB, BigInteger liquidity, BigInteger amountAMin, BigInteger amountBMin,
        string to, BigInteger deadline)
    {
        var contract = new Web3().Eth.GetContract(RouterAbi, _settings.RouterAddress);
        return contract.GetFunction("removeLiquidity")
            .GetData(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    public string EncodeRemoveLiquidityEth(
        string token, BigInteger liquidity, BigInteger amountTokenMin, BigInteger amountEthMin,
        string to, BigInteger deadline)
    {
        var contract = new Web3().Eth.GetContract(RouterAbi, _settings.RouterAddress);
        return contract.GetFunction("removeLiquidityETH")
            .GetData(token, liquidity, amountTokenMin, amountEthMin, to, deadline);
    }

    public string EncodeSwapTokensForTokens(
        BigInteger amountIn, BigInteger amountOutMin, string[] path, string to, BigInteger deadline)
    {
        var contract = new Web3().Eth.GetContract(RouterAbi, _settings.RouterAddress);
        return contract.GetFunction("swapExactTokensForTokensSupportingFeeOnTransferTokens")
            .GetData(amountIn, amountOutMin, path, to, deadline);
    }

    public string EncodeSwapEthForTokens(BigInteger amountOutMin, string[] path, string to, BigInteger deadline)
    {
        var contract = new Web3().Eth.GetContract(RouterAbi, _settings.RouterAddress);
        return contract.GetFunction("swapExactETHForTokensSupportingFeeOnTransferTokens")
            .GetData(amountOutMin, path, to, deadline);
    }

    public string EncodeLockTokens(string token, BigInteger amount, BigInteger unlockTime)
    {
        var contract = new Web3().Eth.GetContract(LockerAbi, _settings.LockerAddress);
        return contract.GetFunction("lockTokens").GetData(token, amount, unlockTime);
    }

    public string EncodeLockWithdraw(BigInteger lockId)
    {
        var contract = new Web3().Eth.GetContract(LockerAbi, _settings.LockerAddress);
        return contract.GetFunction("withdraw").GetData(lockId);
    }

    public string EncodeSwapTokensForEth(
        BigInteger amountIn, BigInteger amountOutMin, string[] path, string to, BigInteger deadline)
    {
        var contract = new Web3().Eth.GetContract(RouterAbi, _settings.RouterAddress);
        return contract.GetFunction("swapExactTokensForETHSupportingFeeOnTransferTokens")
            .GetData(amountIn, amountOutMin, path, to, deadline);
    }
}

[FunctionOutput]
public class PairReservesDto : IFunctionOutputDTO
{
    [Parameter("uint112", "reserve0", 1)]
    public BigInteger Reserve0 { get; set; }

    [Parameter("uint112", "reserve1", 2)]
    public BigInteger Reserve1 { get; set; }

    [Parameter("uint32", "blockTimestampLast", 3)]
    public uint BlockTimestampLast { get; set; }

    public string Token0 { get; set; } = "";
    public string Token1 { get; set; } = "";
}

[FunctionOutput]
public class LockDto : IFunctionOutputDTO
{
    [Parameter("address", "token", 1)]
    public string Token { get; set; } = "";

    [Parameter("address", "owner", 2)]
    public string Owner { get; set; } = "";

    [Parameter("uint256", "amount", 3)]
    public BigInteger Amount { get; set; }

    [Parameter("uint256", "unlockTime", 4)]
    public BigInteger UnlockTime { get; set; }

    [Parameter("bool", "withdrawn", 5)]
    public bool Withdrawn { get; set; }
}
