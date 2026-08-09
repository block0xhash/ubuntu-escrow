using System.Globalization;
using System.Numerics;

namespace GswapApp.Web.Services;

/// <summary>
/// Decimal-string &lt;-&gt; wei conversion done via string/BigInteger arithmetic rather
/// than double, since `double` can't represent 10^18 exactly and silently corrupts
/// token amounts at the precision this app deals in.
/// </summary>
public static class TokenAmount
{
    public static BigInteger ToWei(string? humanAmount, int decimals)
    {
        if (string.IsNullOrWhiteSpace(humanAmount)) return BigInteger.Zero;
        if (!decimal.TryParse(humanAmount, NumberStyles.Number, CultureInfo.InvariantCulture, out var value) || value < 0)
        {
            return BigInteger.Zero;
        }

        var whole = Math.Truncate(value);
        var fraction = value - whole;

        var scale = BigInteger.Pow(10, decimals);
        var wholeWei = new BigInteger(whole) * scale;

        var fractionStr = fraction.ToString(CultureInfo.InvariantCulture);
        var dotIndex = fractionStr.IndexOf('.');
        var fractionDigits = dotIndex >= 0 ? fractionStr[(dotIndex + 1)..] : "";
        if (fractionDigits.Length > decimals) fractionDigits = fractionDigits[..decimals];
        fractionDigits = fractionDigits.PadRight(decimals, '0');

        var fractionWei = fractionDigits.Length == 0 ? BigInteger.Zero : BigInteger.Parse(fractionDigits);
        return wholeWei + fractionWei;
    }

    public static string FromWei(BigInteger wei, int decimals, int displayDecimals = 6)
    {
        if (wei.IsZero) return "0";

        var scale = BigInteger.Pow(10, decimals);
        var whole = BigInteger.DivRem(wei, scale, out var remainder);
        if (remainder.IsZero) return whole.ToString(CultureInfo.InvariantCulture);

        var remainderStr = remainder.ToString(CultureInfo.InvariantCulture).PadLeft(decimals, '0');
        if (remainderStr.Length > displayDecimals) remainderStr = remainderStr[..displayDecimals];
        remainderStr = remainderStr.TrimEnd('0');

        return remainderStr.Length == 0
            ? whole.ToString(CultureInfo.InvariantCulture)
            : $"{whole}.{remainderStr}";
    }
}
