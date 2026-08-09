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

    // eth_requestAccounts alone only prompts the first time a site asks - once
    // permission is granted, it silently hands back whatever was approved before, with
    // no way for the user to pick a different account for this specific connection.
    // wallet_requestPermissions always reopens MetaMask's account picker, letting them
    // actively choose (or multi-select) which account(s) this site gets, every time
    // "Connect Wallet" is clicked.
    connect: async () => {
        if (!window.ethereum) throw new Error('No wallet extension found.');
        await window.ethereum.request({
            method: 'wallet_requestPermissions',
            params: [{ eth_accounts: {} }]
        });
        return await window.ethereum.request({ method: 'eth_requestAccounts' });
    },

    // Wires MetaMask's own change events straight into the Blazor circuit, so the UI
    // reflects whatever network/account the wallet is actually on right now instead of
    // a value captured once at connect time.
    //
    // Re-attaches on every call rather than a "register once ever" guard: a Blazor
    // Server circuit can be torn down and recreated (a dropped SignalR connection that
    // reconnects past its resume window, a full page reload) without window.ethereum
    // itself being reset, since it's injected once per page/tab, not per circuit. A
    // "did I already run this?" flag on window.ethereum would leave the new circuit's
    // dotNetRef never registered while a stale one from the torn-down circuit keeps
    // "holding" the listener slot - accountsChanged/chainChanged would still fire, but
    // straight into a disposed .NET object that can't do anything with them. Removing
    // the previous listener before attaching the new one avoids that without leaking
    // handlers across repeated registrations either.
    registerEvents: (dotNetRef) => {
        if (!window.ethereum) return;

        if (window.ethereum.__gswapChainHandler) {
            window.ethereum.removeListener('chainChanged', window.ethereum.__gswapChainHandler);
        }
        if (window.ethereum.__gswapAccountsHandler) {
            window.ethereum.removeListener('accountsChanged', window.ethereum.__gswapAccountsHandler);
        }

        window.ethereum.__gswapChainHandler = (chainIdHex) => {
            dotNetRef.invokeMethodAsync('OnChainChanged', chainIdHex);
        };
        window.ethereum.__gswapAccountsHandler = (accounts) => {
            dotNetRef.invokeMethodAsync('OnAccountsChanged', accounts && accounts.length > 0 ? accounts[0] : null);
        };

        window.ethereum.on('chainChanged', window.ethereum.__gswapChainHandler);
        window.ethereum.on('accountsChanged', window.ethereum.__gswapAccountsHandler);
    },

    // MetaMask has no API for a site to revoke its own connection - once granted, the
    // permission persists until the user removes it from the extension's own "Connected
    // sites" list. So "Disconnect" here can only ever mean "forget it locally," and that
    // has to be remembered past a reload or eth_accounts will just hand the same account
    // straight back on next page load, silently undoing the disconnect.
    setDisconnected: (value) => {
        if (value) {
            localStorage.setItem('gswap_wallet_disconnected', '1');
        } else {
            localStorage.removeItem('gswap_wallet_disconnected');
        }
    },

    isDisconnected: () => localStorage.getItem('gswap_wallet_disconnected') === '1',
};
