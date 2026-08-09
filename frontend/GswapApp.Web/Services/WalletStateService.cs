using Microsoft.JSInterop;

namespace GswapApp.Web.Services;

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
    /// </summary>
    public async Task InitializeAsync()
    {
        try
        {
            var accounts = await _jsRuntime.InvokeAsync<string[]>("gswapWallet.getAccounts");
            if (accounts is { Length: > 0 })
            {
                ConnectedWallet = accounts[0];
            }

            ConnectedChainIdHex = await _jsRuntime.InvokeAsync<string?>("gswapWallet.getChainId");

            _selfRef = DotNetObjectReference.Create(this);
            await _jsRuntime.InvokeVoidAsync("gswapWallet.registerEvents", _selfRef);

            NotifyStateChanged();
        }
        catch
        {
            // No injected wallet (window.ethereum undefined) or JS not ready yet -
            // leave state at its disconnected defaults.
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

    public async Task ConnectAsync()
    {
        try
        {
            var accounts = await _jsRuntime.InvokeAsync<string[]>(
                "eval", "window.ethereum.request({ method: 'eth_requestAccounts' })");

            if (accounts != null && accounts.Length > 0)
            {
                ConnectedWallet = accounts[0];
            }

            ConnectedChainIdHex = await _jsRuntime.InvokeAsync<string?>("gswapWallet.getChainId");
            NotifyStateChanged();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Wallet connection failed: {ex.Message}");
        }
    }

    public Task DisconnectAsync()
    {
        ConnectedWallet = string.Empty;
        NotifyStateChanged();
        return Task.CompletedTask;
    }

    private void NotifyStateChanged() => OnWalletChanged?.Invoke();

    /// <summary>
    /// Sends a transaction through MetaMask and polls for the receipt, throwing if it
    /// reverted. `valueHex`/`dataHex` are pre-encoded by the caller (GswapContractService
    /// for calldata, plain "0x0" or a wei hex string for value) - this method only owns
    /// the wallet round-trip, not ABI encoding.
    /// </summary>
    public async Task<string> SendTransactionAsync(string to, string valueHex, string dataHex, string gasHex = "0x4C4B40")
    {
        await EnsureCorrectNetworkAsync();

        string script = $@"
            (async () => {{
                const provider = window.ethereum;
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
            window.ethereum.request({{
                method: 'wallet_switchEthereumChain',
                params: [{{ chainId: '{_settings.ChainIdHex}' }}]
            }}).catch(async (switchError) => {{
                if (switchError.code === 4902) {{
                    await window.ethereum.request({{
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
        ");
    }

    public void Dispose()
    {
        _selfRef?.Dispose();
    }
}
