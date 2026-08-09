using GswapApp.Web.Shared;
using MudBlazor;

namespace GswapApp.Web.Services;

/// <summary>
/// The one place "connect a wallet" actually happens from a UI event handler: shows the
/// wallet picker when there's a real choice, calls WalletStateService.ConnectAsync, and
/// catches whatever it throws (a rejected connection request, no wallet installed, etc.)
/// so it becomes a Snackbar instead of an unhandled exception that tears down the whole
/// Blazor circuit. Every "Connect Wallet" button (app bar, Swap, Pool, ...) should go
/// through this rather than calling WalletStateService.ConnectAsync directly - that's
/// exactly the gap that let a rejected connection crash the circuit from the Swap page's
/// own inline button, even though the app bar's button already handled it correctly.
/// </summary>
public class WalletConnectHelper
{
    private readonly WalletStateService _walletState;
    private readonly IDialogService _dialogService;
    private readonly ISnackbar _snackbar;

    public WalletConnectHelper(WalletStateService walletState, IDialogService dialogService, ISnackbar snackbar)
    {
        _walletState = walletState;
        _dialogService = dialogService;
        _snackbar = snackbar;
    }

    /// <returns>true if a wallet ended up connected, false if the user cancelled the
    /// picker or the connection attempt failed (a Snackbar is already shown either way).</returns>
    public async Task<bool> TryConnectAsync()
    {
        try
        {
            var wallets = await _walletState.GetAvailableWalletsAsync();

            string? rdns = null;
            if (wallets.Count > 1)
            {
                var parameters = new DialogParameters<WalletSelectDialog> { { x => x.Wallets, wallets } };
                var dialog = await _dialogService.ShowAsync<WalletSelectDialog>("Select a wallet", parameters);
                var result = await dialog.Result;
                if (result is null || result.Canceled || result.Data is not WalletOption picked) return false;
                rdns = picked.Rdns;
            }

            await _walletState.ConnectAsync(rdns);
            return true;
        }
        catch (Exception ex)
        {
            _snackbar.Add($"Couldn't connect wallet: {ex.Message}", Severity.Error);
            return false;
        }
    }
}
