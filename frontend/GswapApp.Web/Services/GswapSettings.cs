namespace GswapApp.Web.Services;

public class TokenInfo
{
    public string Symbol { get; set; } = "";
    public string Name { get; set; } = "";
    public string Address { get; set; } = "";
    public int Decimals { get; set; } = 18;

    public bool IsNative => string.Equals(Symbol, "ETH", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// Bound from the "Gswap" appsettings.json section. Contract addresses ship as the
/// zero address until DeployGswap.s.sol has actually been run against GIWA - the UI
/// treats a zero RouterAddress/FactoryAddress/WethAddress as "not deployed yet" and
/// shows a banner instead of pretending the DEX works.
/// </summary>
public class GswapSettings
{
    public const string SectionName = "Gswap";
    public const string ZeroAddress = "0x0000000000000000000000000000000000000000";

    public string RpcUrl { get; set; } = "";
    public string BlockExplorerUrl { get; set; } = "";
    public string ChainIdHex { get; set; } = "";
    public int ChainId { get; set; }
    public string ChainName { get; set; } = "";
    public string FactoryAddress { get; set; } = ZeroAddress;
    public string RouterAddress { get; set; } = ZeroAddress;
    public string WethAddress { get; set; } = ZeroAddress;
    public string LockerAddress { get; set; } = ZeroAddress;
    public List<TokenInfo> Tokens { get; set; } = new();

    public bool IsDeployed =>
        !IsZero(RouterAddress) && !IsZero(FactoryAddress) && !IsZero(WethAddress);

    public bool IsLockerDeployed => !IsZero(LockerAddress);

    private static bool IsZero(string address) =>
        string.IsNullOrWhiteSpace(address) || string.Equals(address, ZeroAddress, StringComparison.OrdinalIgnoreCase);

    public TokenInfo NativeEth => new() { Symbol = "ETH", Name = "Ether", Address = "", Decimals = 18 };

    public IEnumerable<TokenInfo> AllSelectableTokens()
    {
        yield return NativeEth;
        foreach (var token in Tokens)
        {
            yield return token;
        }
    }
}
