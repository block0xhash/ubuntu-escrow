using System.Globalization;
using System.Linq;
using Microsoft.AspNetCore.Mvc;
using Dapper;
using Microsoft.Data.Sqlite;
using EscrowApp.Web.Models;

[ApiController]
[Route("api/deals")]
public class DealsController : ControllerBase
{
    private readonly string _connectionString = "Data Source=escrow.db";

    [HttpGet]
    public async Task<IActionResult> GetDeals()
    {
        using var connection = new SqliteConnection(_connectionString);
        var deals = await connection.QueryAsync<DealModel>(
            "SELECT Id, Title, Description, SellerWallet, BuyerWallet, Amount, DealType, Status, TargetBuyerWallet, DepositTxHash, DepositTimestamp, ShipTxHash, ShipTimestamp, ReleaseTxHash, ReleaseTimestamp FROM Deals"
        );

        return Ok(deals.Select(ToResponse));
    }

    [HttpPost]
    public async Task<IActionResult> CreateDeal([FromBody] CreateDealRequest request)
    {
        using var connection = new SqliteConnection(_connectionString);
        var amountText = request.Amount;

        var insertedId = await connection.ExecuteScalarAsync<long>(
            "INSERT INTO Deals (Title, Description, SellerWallet, BuyerWallet, Amount, DealType, Status, TargetBuyerWallet) VALUES (@Title, @Description, @SellerWallet, @BuyerWallet, @Amount, @DealType, @Status, @TargetBuyerWallet); SELECT last_insert_rowid();",
            new { request.Title, request.Description, request.SellerWallet, request.BuyerWallet, Amount = amountText, request.DealType, Status = "Created", request.TargetBuyerWallet }
        );

        var deal = await GetDealResponseAsync(insertedId);
        return CreatedAtAction(nameof(GetDeal), new { id = insertedId }, deal);
    }

    [HttpGet("next-id")]
    public async Task<IActionResult> GetNextId()
    {
        using var connection = new SqliteConnection(_connectionString);
        var nextId = await connection.QueryFirstOrDefaultAsync<long?>("SELECT MAX(Id) FROM Deals") ?? 0;
        return Ok(new NextIdResponse { NextId = nextId + 1 });
    }

    [HttpGet("{id}")]
    public async Task<IActionResult> GetDeal(int id)
    {
        using var connection = new SqliteConnection(_connectionString);
        var deal = await connection.QueryFirstOrDefaultAsync<DealModel>(
            "SELECT Id, Title, Description, SellerWallet, BuyerWallet, Amount, DealType, Status, TargetBuyerWallet, DepositTxHash, DepositTimestamp, ShipTxHash, ShipTimestamp, ReleaseTxHash, ReleaseTimestamp FROM Deals WHERE Id = @Id",
            new { Id = id }
        );

        if (deal == null)
            return NotFound();

        return Ok(ToResponse(deal));
    }

    [HttpPost("metadata")]
    public async Task<IActionResult> SaveMetadata([FromBody] DealMetadataRequest request)
    {
        using var connection = new SqliteConnection(_connectionString);
        var existingId = await connection.QueryFirstOrDefaultAsync<int?>("SELECT Id FROM Deals WHERE Id = @Id", new { Id = request.DealId });
        var amountText = request.AmountEth.ToString(CultureInfo.InvariantCulture);

        if (existingId.HasValue)
        {
            await connection.ExecuteAsync(
                "UPDATE Deals SET Title = @Title, Description = @Description, SellerWallet = @SellerWallet, BuyerWallet = @BuyerWallet, Amount = @Amount, DealType = @DealType, TargetBuyerWallet = @TargetBuyerWallet, Status = @Status WHERE Id = @Id",
                new { Id = request.DealId, request.Title, request.Description, request.SellerWallet, request.BuyerWallet, Amount = amountText, request.DealType, request.TargetBuyerWallet, Status = "Created" }
            );
        }
        else
        {
            await connection.ExecuteAsync(
                "INSERT INTO Deals (Id, Title, Description, SellerWallet, BuyerWallet, Amount, DealType, Status, TargetBuyerWallet) VALUES (@Id, @Title, @Description, @SellerWallet, @BuyerWallet, @Amount, @DealType, @Status, @TargetBuyerWallet)",
                new { Id = request.DealId, request.Title, request.Description, request.SellerWallet, request.BuyerWallet, Amount = amountText, request.DealType, Status = "Created", request.TargetBuyerWallet }
            );
        }

        var deal = await GetDealResponseAsync(request.DealId);
        return Ok(deal);
    }

    [HttpPost("{id}/fund")]
    public async Task<IActionResult> FundDeal(int id, [FromBody] FundDealRequest request)
    {
        using var connection = new SqliteConnection(_connectionString);
        var affected = await connection.ExecuteAsync(
            "UPDATE Deals SET Status = 'Funded', BuyerWallet = @BuyerWallet, DepositTxHash = @TxHash, DepositTimestamp = @Timestamp WHERE Id = @Id",
            new { Id = id, BuyerWallet = request.BuyerWallet, TxHash = request.TxHash, Timestamp = request.Timestamp }
        );

        if (affected == 0) return NotFound();
        return Ok(new { success = true });
    }

    [HttpPost("{id}/ship")]
    public async Task<IActionResult> ShipDeal(int id, [FromBody] ShipDealRequest request)
    {
        using var connection = new SqliteConnection(_connectionString);
        var affected = await connection.ExecuteAsync(
            "UPDATE Deals SET Status = 'Shipped', ShipTxHash = @TxHash, ShipTimestamp = @Timestamp WHERE Id = @Id",
            new { Id = id, TxHash = request.TxHash, Timestamp = request.Timestamp }
        );

        if (affected == 0) return NotFound();
        return Ok(new { success = true });
    }

    [HttpPost("{id}/release")]
    public async Task<IActionResult> ReleaseDeal(int id, [FromBody] ReleaseDealRequest request)
    {
        using var connection = new SqliteConnection(_connectionString);
        var affected = await connection.ExecuteAsync(
            "UPDATE Deals SET Status = 'Released', ReleaseTxHash = @TxHash, ReleaseTimestamp = @Timestamp WHERE Id = @Id",
            new { Id = id, TxHash = request.TxHash, Timestamp = request.Timestamp }
        );

        if (affected == 0) return NotFound();
        return Ok(new { success = true });
    }

    private DealResponse ToResponse(DealModel row)
    {
        var amountEth = 0m;
        if (!string.IsNullOrEmpty(row.Amount))
        {
            decimal.TryParse(row.Amount, NumberStyles.Any, CultureInfo.InvariantCulture, out amountEth);
        }

        return new DealResponse
        {
            DealId = row.Id,
            Title = row.Title,
            Description = row.Description,
            SellerWallet = row.SellerWallet,
            BuyerWallet = row.BuyerWallet,
            Amount = row.Amount,
            AmountEth = amountEth,
            DealType = row.DealType,
            Status = string.IsNullOrEmpty(row.Status) ? "Created" : row.Status,
            TargetBuyerWallet = row.TargetBuyerWallet,
            DepositTxHash = row.DepositTxHash,
            DepositTimestamp = row.DepositTimestamp,
            ShipTxHash = row.ShipTxHash,
            ShipTimestamp = row.ShipTimestamp,
            ReleaseTxHash = row.ReleaseTxHash,
            ReleaseTimestamp = row.ReleaseTimestamp,
            Metadata = new DealMetadataModel
            {
                DealId = row.Id,
                Title = row.Title,
                Description = row.Description,
                SellerWallet = row.SellerWallet,
                BuyerWallet = row.BuyerWallet,
                AmountEth = amountEth,
                DealType = row.DealType,
                TargetBuyerWallet = row.TargetBuyerWallet,
                Status = string.IsNullOrEmpty(row.Status) ? "Created" : row.Status
            }
        };
    }

    private async Task<DealResponse> GetDealResponseAsync(long id)
    {
        using var connection = new SqliteConnection(_connectionString);
        var row = await connection.QueryFirstOrDefaultAsync<DealModel>(
            "SELECT Id, Title, Description, SellerWallet, BuyerWallet, Amount, DealType, Status, TargetBuyerWallet, DepositTxHash, DepositTimestamp, ShipTxHash, ShipTimestamp, ReleaseTxHash, ReleaseTimestamp FROM Deals WHERE Id = @Id",
            new { Id = id }
        );

        return ToResponse(row!);
    }
}

public class DealModel
{
    public int Id { get; set; }
    public string Title { get; set; } = "";
    public string Description { get; set; } = "";
    public string SellerWallet { get; set; } = "";
    public string BuyerWallet { get; set; } = "";
    public string Amount { get; set; } = "";
    public string DealType { get; set; } = "";
    public string Status { get; set; } = "";
    public string TargetBuyerWallet { get; set; } = "";
    public string DepositTxHash { get; set; } = "";
    public string DepositTimestamp { get; set; } = "";
    public string ShipTxHash { get; set; } = "";
    public string ShipTimestamp { get; set; } = "";
    public string ReleaseTxHash { get; set; } = "";
    public string ReleaseTimestamp { get; set; } = "";
}

public class DealResponse
{
    public long DealId { get; set; }
    public long Id => DealId;
    public string Title { get; set; } = "";
    public string Description { get; set; } = "";
    public string SellerWallet { get; set; } = "";
    public string BuyerWallet { get; set; } = "";
    public string Amount { get; set; } = "";
    public decimal AmountEth { get; set; }
    public string DealType { get; set; } = "";
    public string Status { get; set; } = "";
    public string TargetBuyerWallet { get; set; } = "";
    public string DepositTxHash { get; set; } = "";
    public string DepositTimestamp { get; set; } = "";
    public string ShipTxHash { get; set; } = "";
    public string ShipTimestamp { get; set; } = "";
    public string ReleaseTxHash { get; set; } = "";
    public string ReleaseTimestamp { get; set; } = "";
    public DealMetadataModel Metadata { get; set; } = new();
}

public class NextIdResponse
{
    public long NextId { get; set; }
}

public class FundDealRequest
{
    public string BuyerWallet { get; set; } = "";
    public string TxHash { get; set; } = "";
    public string Timestamp { get; set; } = "";
}

public class ShipDealRequest
{
    public string TxHash { get; set; } = "";
    public string Timestamp { get; set; } = "";
}

public class ReleaseDealRequest
{
    public string TxHash { get; set; } = "";
    public string Timestamp { get; set; } = "";
}

public class CreateDealRequest
{
    public string Title { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string SellerWallet { get; set; } = string.Empty;
    public string BuyerWallet { get; set; } = string.Empty;
    public string Amount { get; set; } = string.Empty;
    public string DealType { get; set; } = string.Empty;
    public string TargetBuyerWallet { get; set; } = string.Empty;
}
