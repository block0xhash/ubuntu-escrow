// Thin wrapper around window.ethereum for the parts that need a real, persistent
// JS listener rather than a one-shot eval call (chain/account changes fire whenever
// MetaMask feels like it, not in response to something Blazor initiated).
window.gswapWallet = {
    getChainId: async () => {
        if (!window.ethereum) return null;
        return await window.ethereum.request({ method: 'eth_chainId' });
    },

    getAccounts: async () => {
        if (!window.ethereum) return [];
        return await window.ethereum.request({ method: 'eth_accounts' });
    },

    // Wires MetaMask's own change events straight into the Blazor circuit, so the UI
    // reflects whatever network/account the wallet is actually on right now instead of
    // a value captured once at connect time.
    registerEvents: (dotNetRef) => {
        if (!window.ethereum || window.ethereum.__gswapListenersAttached) return;
        window.ethereum.__gswapListenersAttached = true;

        window.ethereum.on('chainChanged', (chainIdHex) => {
            dotNetRef.invokeMethodAsync('OnChainChanged', chainIdHex);
        });

        window.ethereum.on('accountsChanged', (accounts) => {
            dotNetRef.invokeMethodAsync('OnAccountsChanged', accounts && accounts.length > 0 ? accounts[0] : null);
        });
    }
};
