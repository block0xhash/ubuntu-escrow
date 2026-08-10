using System.Numerics;

namespace GswapApp.Web.Services;

/// <summary>
/// Everything the scanner could determine about one newly-deployed contract. Every
/// signal here is a cheap heuristic (bytecode probes, Blockscout's verification flag,
/// whether a GSWAP pool exists) - not a security audit. IsVerified is nullable
/// specifically to distinguish "confirmed unverified" from "explorer hasn't indexed it
/// yet / lookup failed," which a bare bool would silently conflate.
/// </summary>
public class ScannedContract
{
    public string Address { get; set; } = "";
    public long BlockNumber { get; set; }

    /// <summary>The block's own timestamp, not when the scanner happened to process it -
    /// matters because backfilled history is all scanned in a burst at startup, so
    /// "now" would be wrong for anything older than a few seconds.</summary>
    public DateTimeOffset DeployedAt { get; set; }

    public string? Deployer { get; set; }

    public bool? IsVerified { get; set; }
    public string? ContractName { get; set; }

    public bool LooksLikeErc20 { get; set; }
    public string? TokenSymbol { get; set; }
    public int Decimals { get; set; } = 18;
    public BigInteger? TotalSupply { get; set; }

    public bool HasOwnerFunction { get; set; }
    public bool OwnershipRenounced { get; set; }

    public string? GswapPairAddress { get; set; }
    public bool HasGswapLiquidity => GswapPairAddress != null;
    public BigInteger? LiquidityTokenReserve { get; set; }
    public BigInteger? LiquidityWethReserve { get; set; }

    /// <summary>0-100, computed by ContractScannerService.ComputeScore. A rough signal
    /// combining the flags above, not a guarantee of safety.</summary>
    public int SafetyScore { get; set; }
}
