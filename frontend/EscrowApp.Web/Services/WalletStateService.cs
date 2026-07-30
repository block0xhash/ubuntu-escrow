using Microsoft.JSInterop;
using System;
using System.Threading.Tasks;

namespace EscrowApp.Web.Services
{
    public class WalletStateService
    {
        private readonly IJSRuntime _jsRuntime;
        
        public string ConnectedWallet { get; private set; } = string.Empty;
        public event Action? OnWalletChanged;

        public WalletStateService(IJSRuntime jsRuntime)
        {
            _jsRuntime = jsRuntime;
        }

        public async Task CheckConnectionAsync()
        {
            try
            {
                // Silently check if MetaMask already has an account connected to this site
                var accounts = await _jsRuntime.InvokeAsync<string[]>("eval", "window.ethereum ? window.ethereum.request({ method: 'eth_accounts' }) : []");
                
                if (accounts != null && accounts.Length > 0)
                {
                    ConnectedWallet = accounts[0];
                    NotifyStateChanged();
                }
            }
            catch
            {
                // Suppress errors during silent check (e.g., if extension is not installed)
            }
        }

        public async Task ConnectAsync()
        {
            try
            {
                // Prompt MetaMask popup for user to approve connection
                var accounts = await _jsRuntime.InvokeAsync<string[]>("eval", "window.ethereum.request({ method: 'eth_requestAccounts' })");
                
                if (accounts != null && accounts.Length > 0)
                {
                    ConnectedWallet = accounts[0];
                    NotifyStateChanged();
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Wallet connection failed: {ex.Message}");
            }
        }

        public Task DisconnectAsync()
        {
            // Web3 dApps cannot force MetaMask to disconnect via code, 
            // but we clear the local application state to simulate logging out.
            ConnectedWallet = string.Empty;
            NotifyStateChanged();
            return Task.CompletedTask;
        }

        private void NotifyStateChanged() => OnWalletChanged?.Invoke();
    }
}
