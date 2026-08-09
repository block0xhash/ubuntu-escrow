using Microsoft.JSInterop;

namespace GswapApp.Web.Services;

public record WalletOption(string Uuid, string Name, string Rdns);

public class WalletStateService : IDisposable
{
    private readonly IJSRuntime _jsRuntime;
    private readonly GswapSettings _settings;
    private DotNetObjectReference<WalletStateService>? _selfRef;

    public string ConnectedWallet { get; private set; } = string.Empty;

    /// <summary>
    /// The chain ID MetaMask itself reports right now (0x-hex), kept live via the
    /// chainChanged event - never a value assumed from config, since the whole point is
    /// showing what the wallet is actually connected to, not what this app expects.
    /// </summary>
    public string? ConnectedChainIdHex { get; private set; }

    public event Action? OnWalletChanged;

    public WalletStateService(IJSRuntime jsRuntime, GswapSettings settings)
    {
        _jsRuntime = jsRuntime;
        _settings = settings;
    }

    /// <summary>
    /// Reads current wallet/chain state and subscribes to MetaMask's own change events
    /// so ConnectedChainIdHex/ConnectedWallet track reality even when the user switches
    /// network or account from inside the wallet, not just through this app's UI.
    /// Always re-registers the JS listeners (see wallet.js) rather than assuming a prior
    /// registration is still live, since this can legitimately run again after a Blazor
    /// Server circuit is torn down and recreated.
    /// </summary>
    public async Task InitializeAsync()
    {
        try
        {
            _selfRef ??= DotNetObjectReference.Create(this);
            await _jsRuntime.InvokeVoidAsync("gswapWallet.registerEvents", _selfRef);

            ConnectedChainIdHex = await _jsRuntime.InvokeAsync<string?>("gswapWallet.getChainId");

            // Respect an explicit prior disconnect: no wallet has a concept of a site
            // disconnecting itself, so eth_accounts would otherwise just hand back the
            // same account and silently undo the user's choice on every reload.
            var disconnected = await _jsRuntime.InvokeAsync<bool>("gswapWallet.isDisconnected");
            if (!disconnected)
            {
                var accounts = await _jsRuntime.InvokeAsync<string[]>("gswapWallet.getAccounts");
                if (accounts is { Length: > 0 })
                {
                    ConnectedWallet = accounts[0];
                }
            }

            NotifyStateChanged();
        }
        catch
        {
            // No injected wallet or JS not ready yet - leave state at its disconnected
            // defaults.
        }
    }

    /// <summary>
    /// Every wallet extension currently installed that announced itself via EIP-6963
    /// (MetaMask, Phantom's EVM support, Coinbase Wallet, etc. all do). Empty if none
    /// support it, in which case ConnectAsync(null) falls back to legacy window.ethereum.
    /// </summary>
    public async Task<List<WalletOption>> GetAvailableWalletsAsync()
    {
        try
        {
            return await _jsRuntime.InvokeAsync<List<WalletOption>>("gswapWallet.getAvailableWallets");
        }
        catch
        {
            return new List<WalletOption>();
        }
    }

    [JSInvokable]
    public void OnChainChanged(string? chainIdHex)
    {
        ConnectedChainIdHex = chainIdHex;
        NotifyStateChanged();
    }

    [JSInvokable]
    public void OnAccountsChanged(string? account)
    {
        ConnectedWallet = account ?? string.Empty;
        NotifyStateChanged();
    }

    /// <summary>
    /// rdns identifies a specific wallet from GetAvailableWalletsAsync (pass null when
    /// there's zero or one candidate and no choice to make). Throws WalletConnectException
    /// with a real, human-readable message on failure - callers are expected to catch and
    /// show it, not just log it, since a silently-swallowed connect failure is exactly
    /// what left this undiagnosable before.
    /// </summary>
    public async Task ConnectAsync(string? rdns = null)
    {
        var accounts = await _jsRuntime.InvokeAsync<string[]>("gswapWallet.connect", rdns);

        if (accounts != null && accounts.Length > 0)
        {
            ConnectedWallet = accounts[0];
        }

        ConnectedChainIdHex = await _jsRuntime.InvokeAsync<string?>("gswapWallet.getChainId");
        await _jsRuntime.InvokeVoidAsync("gswapWallet.setDisconnected", false);
        NotifyStateChanged();
    }

    public async Task DisconnectAsync()
    {
        ConnectedWallet = string.Empty;
        await _jsRuntime.InvokeVoidAsync("gswapWallet.setDisconnected", true);
        NotifyStateChanged();
    }

    private void NotifyStateChanged() => OnWalletChanged?.Invoke();

    /// <summary>
    /// Sends a transaction through the wallet and polls for the receipt, throwing if it
    /// reverted. `valueHex`/`dataHex` are pre-encoded by the caller (GswapContractService
    /// for calldata, plain "0x0" or a wei hex string for value) - this method only owns
    /// the wallet round-trip, not ABI encoding. Goes through gswapWallet.getActiveProvider()
    /// rather than window.ethereum directly, so it actually uses whichever wallet the user
    /// selected (see wallet.js) instead of silently defaulting to whatever wins the
    /// legacy global slot when multiple extensions are installed.
    /// </summary>
    public async Task<string> SendTransactionAsync(string to, string valueHex, string dataHex, string gasHex = "0x4C4B40")
    {
        await EnsureCorrectNetworkAsync();

        string script = $@"
            (async () => {{
                const provider = window.gswapWallet.getActiveProvider();
                if (!provider) throw new Error('No wallet extension found.');
                const txHash = await provider.request({{
                    method: 'eth_sendTransaction',
                    params: [{{
                        from: '{ConnectedWallet}',
                        to: '{to}',
                        value: '{valueHex}',
                        data: '{dataHex}',
                        gas: '{gasHex}'
                    }}]
                }});

                let receipt = null;
                while (receipt === null) {{
                    await new Promise(r => setTimeout(r, 1000));
                    receipt = await provider.request({{
                        method: 'eth_getTransactionReceipt',
                        params: [txHash]
                    }});
                }}

                if (!receipt || receipt.status === '0x0' || receipt.status === 0) {{
                    throw new Error('Transaction reverted on-chain.');
                }}
                return txHash;
            }})()
        ";
        return await _jsRuntime.InvokeAsync<string>("eval", script);
    }

    public async Task EnsureCorrectNetworkAsync()
    {
        await _jsRuntime.InvokeVoidAsync("eval", $@"
            (async () => {{
                const provider = window.gswapWallet.getActiveProvider();
                if (!provider) throw new Error('No wallet extension found.');
                await provider.request({{
                    method: 'wallet_switchEthereumChain',
                    params: [{{ chainId: '{_settings.ChainIdHex}' }}]
                }}).catch(async (switchError) => {{
                    if (switchError.code === 4902) {{
                        await provider.request({{
                            method: 'wallet_addEthereumChain',
                            params: [{{
                                chainId: '{_settings.ChainIdHex}',
                                chainName: '{_settings.ChainName}',
                                nativeCurrency: {{ name: 'ETH', symbol: 'ETH', decimals: 18 }},
                                rpcUrls: ['{_settings.RpcUrl}'],
                                blockExplorerUrls: ['{_settings.BlockExplorerUrl}']
                            }}]
                        }});
                    }}
                }});
            }})()
        ");
    }

    public void Dispose()
    {
        _selfRef?.Dispose();
    }
}
