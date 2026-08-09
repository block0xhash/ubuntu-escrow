// Multiple installed wallet extensions (MetaMask, Phantom, Coinbase Wallet, etc.) all
// historically fought over the single window.ethereum slot - whichever one wins is
// arbitrary (load order, user settings), and there's no way for a page to ask for a
// *specific* one. EIP-6963 fixes this: each wallet announces itself via a window event
// instead of overwriting a shared global, so a page can discover every installed
// wallet and let the user pick. This file discovers via EIP-6963 first, and only falls
// back to the old single-slot window.ethereum for wallets that don't support it yet.
(() => {
    const providers = new Map(); // uuid -> { info: {uuid, name, icon, rdns}, provider }

    window.addEventListener('eip6963:announceProvider', (event) => {
        const { info, provider } = event.detail;
        providers.set(info.uuid, { info, provider });
    });
    window.dispatchEvent(new Event('eip6963:requestProvider'));

    function resolveActiveProvider() {
        const rememberedRdns = localStorage.getItem('gswap_wallet_rdns');
        if (rememberedRdns) {
            for (const entry of providers.values()) {
                if (entry.info.rdns === rememberedRdns) return entry.provider;
            }
        }
        if (providers.size === 1) {
            return providers.values().next().value.provider;
        }
        // Multiple wallets and no remembered choice (or the remembered one isn't
        // installed anymore) - fall back to whatever legacy window.ethereum resolves
        // to rather than guessing among EIP-6963 entries.
        return window.ethereum || (providers.size > 0 ? providers.values().next().value.provider : null);
    }

    // Normalizes whatever a wallet throws/rejects with into a plain string. Some
    // providers reject with a proper Error, some with a bare {code, message} object,
    // and Blazor's JS interop turns anything that doesn't stringify cleanly into
    // "[object Object]" by the time it reaches .NET - this is what was showing up as
    // an undiagnosable "Wallet connection failed: [object Object]".
    function describeError(err) {
        if (!err) return 'Unknown error';
        if (typeof err === 'string') return err;
        if (err.code === 4001) return 'Connection request was rejected in the wallet.';
        if (err.message) return err.message;
        try {
            return JSON.stringify(err);
        } catch {
            return String(err);
        }
    }

    window.gswapWallet = {
        // Exposed so the eval-string scripts in WalletStateService (transaction sending,
        // network switching) resolve the same explicitly-selected provider instead of
        // reaching for window.ethereum directly and silently bypassing the user's
        // choice of wallet. Only meaningful called from same-context JS, not over the
        // Blazor interop boundary - a live provider object with methods can't cross that.
        getActiveProvider: () => resolveActiveProvider(),

        getAvailableWallets: () => Array.from(providers.values()).map((p) => ({
            uuid: p.info.uuid,
            name: p.info.name,
            rdns: p.info.rdns,
        })),

        getChainId: async () => {
            const provider = resolveActiveProvider();
            if (!provider) return null;
            return await provider.request({ method: 'eth_chainId' });
        },

        getAccounts: async () => {
            const provider = resolveActiveProvider();
            if (!provider) return [];
            return await provider.request({ method: 'eth_accounts' });
        },

        // rdns identifies the specific wallet to connect through (from
        // getAvailableWallets), or null/undefined to use whatever resolveActiveProvider
        // falls back to (the only-one-installed or legacy window.ethereum case).
        // wallet_requestPermissions always reopens the account picker even if this site
        // was already connected, so the user can actively pick a different account
        // instead of silently getting back whatever was approved before.
        connect: async (rdns) => {
            let provider;
            if (rdns) {
                const entry = Array.from(providers.values()).find((p) => p.info.rdns === rdns);
                if (!entry) throw new Error('Selected wallet is no longer available.');
                provider = entry.provider;
                localStorage.setItem('gswap_wallet_rdns', rdns);
            } else {
                provider = resolveActiveProvider();
            }
            if (!provider) throw new Error('No wallet extension found.');

            try {
                await provider.request({ method: 'wallet_requestPermissions', params: [{ eth_accounts: {} }] });
            } catch (err) {
                throw new Error(describeError(err));
            }

            try {
                return await provider.request({ method: 'eth_requestAccounts' });
            } catch (err) {
                throw new Error(describeError(err));
            }
        },

        // Re-attaches on every call rather than a "register once ever" guard: a Blazor
        // Server circuit can be torn down and recreated without window/provider state
        // resetting, so a stale guard would leave the new circuit's dotNetRef never
        // registered while events keep firing into a disposed .NET object instead.
        registerEvents: (dotNetRef) => {
            const provider = resolveActiveProvider();
            if (!provider) return;

            if (provider.__gswapChainHandler) {
                provider.removeListener('chainChanged', provider.__gswapChainHandler);
            }
            if (provider.__gswapAccountsHandler) {
                provider.removeListener('accountsChanged', provider.__gswapAccountsHandler);
            }

            provider.__gswapChainHandler = (chainIdHex) => {
                dotNetRef.invokeMethodAsync('OnChainChanged', chainIdHex);
            };
            provider.__gswapAccountsHandler = (accounts) => {
                dotNetRef.invokeMethodAsync('OnAccountsChanged', accounts && accounts.length > 0 ? accounts[0] : null);
            };

            provider.on('chainChanged', provider.__gswapChainHandler);
            provider.on('accountsChanged', provider.__gswapAccountsHandler);
        },

        // No wallet exposes an API for a site to revoke its own connection - once
        // granted, permission persists until removed from the extension's own
        // "Connected sites" list. So "Disconnect" here can only mean "forget it
        // locally," and that has to be remembered past a reload or eth_accounts will
        // just hand the same account straight back, silently undoing the disconnect.
        setDisconnected: (value) => {
            if (value) {
                localStorage.setItem('gswap_wallet_disconnected', '1');
            } else {
                localStorage.removeItem('gswap_wallet_disconnected');
            }
        },

        isDisconnected: () => localStorage.getItem('gswap_wallet_disconnected') === '1',
    };
})();
