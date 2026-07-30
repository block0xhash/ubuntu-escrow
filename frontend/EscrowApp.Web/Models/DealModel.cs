namespace EscrowApp.Web.Models
{
    public class DealMetadataModel
    {
        public long DealId { get; set; }
        public string Title { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public string BuyerWallet { get; set; } = string.Empty;
        public string SellerWallet { get; set; } = string.Empty;
        public decimal AmountEth { get; set; }
        public string DealType { get; set; } = "Public";
        public string TargetBuyerWallet { get; set; } = string.Empty;
        public string Status { get; set; } = string.Empty;
    }

    public class DealMetadataRequest
    {
        public long DealId { get; set; }
        public string Title { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public string BuyerWallet { get; set; } = string.Empty;
        public string SellerWallet { get; set; } = string.Empty;
        public decimal AmountEth { get; set; }
        public string DealType { get; set; } = "Public";
        public string TargetBuyerWallet { get; set; } = string.Empty;
    }
}
