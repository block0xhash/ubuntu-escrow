using System.Collections.Concurrent;
using System.Numerics;
using System.Text.Json;
using Nethereum.Hex.HexTypes;
using Nethereum.RPC.Eth.DTOs;
using Nethereum.Web3;

namespace GswapApp.Web.Services;

/// <summary>
/// GDOG-01's "network scraping" utility: polls GIWA for newly-deployed contracts and
/// runs a handful of cheap heuristic safety checks on each one. Deliberately does not
/// hold a key or sign anything - read-only RPC calls and one public HTTP lookup against
/// Blockscout. See ScannedContract for exactly what "safety" means here (not much - it's
/// a rough signal, not an audit, and the UI needs to say so plainly rather than let a
/// number imply more confidence than the checks behind it earn).
/// </summary>
public class ContractScannerService : BackgroundService
{
    private const int MaxTracked = 300;
    private const int BackfillBlocks = 200;
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(15);

    private const string ProbeAbi = @"[
        {'name':'symbol','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'string'}]},
        {'name':'decimals','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'uint8'}]},
        {'name':'totalSupply','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'uint256'}]},
        {'name':'owner','type':'function','stateMutability':'view','inputs':[],'outputs':[{'name':'','type':'address'}]}
    ]";

    private readonly GswapSettings _settings;
    private readonly GswapContractService _gswapContracts;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<ContractScannerService> _logger;

    private readonly ConcurrentDictionary<string, ScannedContract> _discovered = new();
    private readonly ConcurrentQueue<string> _order = new();

    public event Action? OnDiscovered;

    public ContractScannerService(
        GswapSettings settings,
        GswapContractService gswapContracts,
        IHttpClientFactory httpClientFactory,
        ILogger<ContractScannerService> logger)
    {
        _settings = settings;
        _gswapContracts = gswapContracts;
        _httpClientFactory = httpClientFactory;
        _logger = logger;
    }

    public IReadOnlyList<ScannedContract> GetDiscovered() =>
        _discovered.Values.OrderByDescending(c => c.BlockNumber).ToList();

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (string.IsNullOrWhiteSpace(_settings.RpcUrl)) return;

        var web3 = new Web3(_settings.RpcUrl);

        BigInteger lastScanned;
        try
        {
            var latest = await web3.Eth.Blocks.GetBlockNumber.SendRequestAsync();
            lastScanned = latest.Value;
            var backfillFrom = BigInteger.Max(0, lastScanned - BackfillBlocks);
            await ScanRangeAsync(web3, backfillFrom, lastScanned, stoppingToken);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "ContractScannerService: initial backfill failed, will retry from next poll");
            lastScanned = 0;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(PollInterval, stoppingToken);
                var current = (await web3.Eth.Blocks.GetBlockNumber.SendRequestAsync()).Value;
                if (current > lastScanned)
                {
                    await ScanRangeAsync(web3, lastScanned + 1, current, stoppingToken);
                    lastScanned = current;
                }
            }
            catch (TaskCanceledException)
            {
                // shutting down
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "ContractScannerService: poll failed, retrying next interval");
            }
        }
    }

    private async Task ScanRangeAsync(Web3 web3, BigInteger fromBlock, BigInteger toBlock, CancellationToken ct)
    {
        for (var blockNumber = fromBlock; blockNumber <= toBlock; blockNumber++)
        {
            if (ct.IsCancellationRequested) return;

            BlockWithTransactions? block;
            try
            {
                block = await web3.Eth.Blocks.GetBlockWithTransactionsByNumber.SendRequestAsync(
                    new BlockParameter(new HexBigInteger(blockNumber)));
            }
            catch
            {
                continue; // transient RPC hiccup on this block - move on, not worth retrying mid-range
            }

            if (block?.Transactions is null) continue;

            // The block's own timestamp, not "now" - matters because backfilled history
            // is all scanned in a burst at startup.
            var deployedAt = DateTimeOffset.FromUnixTimeSeconds((long)block.Timestamp.Value);

            foreach (var tx in block.Transactions)
            {
                if (!string.IsNullOrEmpty(tx.To)) continue; // not a contract creation
                if (ct.IsCancellationRequested) return;

                await TryProcessCreationAsync(web3, tx.TransactionHash, (long)blockNumber, deployedAt, tx.From);
            }
        }
    }

    private async Task TryProcessCreationAsync(
        Web3 web3, string txHash, long blockNumber, DateTimeOffset deployedAt, string? deployer)
    {
        TransactionReceipt receipt;
        try
        {
            receipt = await web3.Eth.Transactions.GetTransactionReceipt.SendRequestAsync(txHash);
        }
        catch
        {
            return;
        }

        if (receipt?.ContractAddress is null) return;
        if (receipt.Status is null || receipt.Status.Value != 1) return; // creation itself reverted

        var address = receipt.ContractAddress;
        if (_discovered.ContainsKey(address)) return;

        var scanned = await AnalyzeAsync(web3, address, blockNumber, deployedAt, deployer);

        _discovered[address] = scanned;
        _order.Enqueue(address);
        while (_order.Count > MaxTracked && _order.TryDequeue(out var oldest))
        {
            _discovered.TryRemove(oldest, out _);
        }

        OnDiscovered?.Invoke();
    }

    private async Task<ScannedContract> AnalyzeAsync(
        Web3 web3, string address, long blockNumber, DateTimeOffset deployedAt, string? deployer)
    {
        var result = new ScannedContract
        {
            Address = address,
            BlockNumber = blockNumber,
            DeployedAt = deployedAt,
            Deployer = deployer,
        };

        var contract = web3.Eth.GetContract(ProbeAbi, address);

        try
        {
            result.TokenSymbol = await contract.GetFunction("symbol").CallAsync<string>();
            result.TotalSupply = await contract.GetFunction("totalSupply").CallAsync<BigInteger>();
            result.LooksLikeErc20 = true;

            try
            {
                result.Decimals = await contract.GetFunction("decimals").CallAsync<byte>();
            }
            catch
            {
                result.Decimals = 18; // most tokens that omit it still use 18
            }
        }
        catch
        {
            result.LooksLikeErc20 = false;
        }

        try
        {
            var owner = await contract.GetFunction("owner").CallAsync<string>();
            result.HasOwnerFunction = true;
            result.OwnershipRenounced = owner == "0x0000000000000000000000000000000000000000";
        }
        catch
        {
            result.HasOwnerFunction = false;
        }

        await CheckVerificationAsync(result);
        await CheckLiquidityAsync(result);

        result.SafetyScore = ComputeScore(result);
        return result;
    }

    private async Task CheckVerificationAsync(ScannedContract result)
    {
        if (string.IsNullOrWhiteSpace(_settings.BlockExplorerUrl)) return;

        try
        {
            using var client = _httpClientFactory.CreateClient();
            client.Timeout = TimeSpan.FromSeconds(8);
            var response = await client.GetAsync($"{_settings.BlockExplorerUrl}/api/v2/smart-contracts/{result.Address}");

            if (!response.IsSuccessStatusCode)
            {
                result.IsVerified = null; // not found / not indexed yet - unknown, not "unverified"
                return;
            }

            using var stream = await response.Content.ReadAsStreamAsync();
            using var doc = await JsonDocument.ParseAsync(stream);

            if (doc.RootElement.TryGetProperty("is_verified", out var verifiedProp))
            {
                result.IsVerified = verifiedProp.GetBoolean();
            }
            if (doc.RootElement.TryGetProperty("name", out var nameProp))
            {
                result.ContractName = nameProp.GetString();
            }
        }
        catch
        {
            result.IsVerified = null;
        }
    }

    private async Task CheckLiquidityAsync(ScannedContract result)
    {
        if (string.IsNullOrEmpty(_settings.WethAddress)) return;

        try
        {
            var pair = await _gswapContracts.GetPairAsync(result.Address, _settings.WethAddress);
            if (string.Equals(pair, GswapSettings.ZeroAddress, StringComparison.OrdinalIgnoreCase)) return;

            result.GswapPairAddress = pair;

            var reserves = await _gswapContracts.GetReservesAsync(pair);
            var tokenIsToken0 = string.Equals(reserves.Token0, result.Address, StringComparison.OrdinalIgnoreCase);
            result.LiquidityTokenReserve = tokenIsToken0 ? reserves.Reserve0 : reserves.Reserve1;
            result.LiquidityWethReserve = tokenIsToken0 ? reserves.Reserve1 : reserves.Reserve0;
        }
        catch
        {
            // factory/pair/reserve lookup failing doesn't tell us anything either way
        }
    }

    /// <summary>Rough, transparent heuristic - not a security audit. Weighted toward the
    /// two signals that actually cost an attacker something to fake (verified source,
    /// real liquidity) over the ones that are trivial to spoof (a token "looking like"
    /// ERC20 just means it has the right function selectors).</summary>
    private static int ComputeScore(ScannedContract c)
    {
        var score = 0;
        if (c.IsVerified == true) score += 35;
        if (c.HasGswapLiquidity) score += 30;
        if (c.LooksLikeErc20) score += 15;
        if (c.LooksLikeErc20 && (!c.HasOwnerFunction || c.OwnershipRenounced)) score += 20;
        return Math.Clamp(score, 0, 100);
    }
}
