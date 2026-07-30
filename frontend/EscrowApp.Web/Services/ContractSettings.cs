
namespace EscrowApp.Web.Services
{
    // Single source of truth for the deployed Escrow contract and the GIWA Sepolia
    // network it lives on. Every page/service that needs these values reads them
    // from here instead of hardcoding its own copy.
    public static class ContractSettings
    {
        public const string EscrowContractAddress = "0xabBDDF83285daa096381E5E4b312afCACA36686a";
        public const string RpcUrl = "https://sepolia-rpc.giwa.io";
        public const string BlockExplorerUrl = "https://sepolia-explorer.giwa.io";
        public const string ChainIdHex = "0x164ce";
        public const int ChainId = 91342;
        public const string ChainName = "GIWA Sepolia Testnet";
    }
}
