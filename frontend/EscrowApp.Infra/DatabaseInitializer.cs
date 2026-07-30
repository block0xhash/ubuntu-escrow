using Microsoft.Data.Sqlite;
using Dapper;

namespace EscrowApp.Infra;

public static class DatabaseInitializer
{
    public static void Initialize()
    {
        using var connection = new SqliteConnection("Data Source=escrow.db");
        connection.Open();

        connection.Execute(@"
            CREATE TABLE IF NOT EXISTS Deals (
                Id INTEGER PRIMARY KEY AUTOINCREMENT,
                Title TEXT,
                Description TEXT,
                SellerWallet TEXT,
                BuyerWallet TEXT,
                Amount TEXT,
                DealType TEXT,
                Status TEXT,
                TargetBuyerWallet TEXT DEFAULT '',
                DepositTxHash TEXT DEFAULT '',
                DepositTimestamp TEXT DEFAULT '',
                ShipTxHash TEXT DEFAULT '',
                ShipTimestamp TEXT DEFAULT '',
                ReleaseTxHash TEXT DEFAULT '',
                ReleaseTimestamp TEXT DEFAULT ''
            );
        ");
        
        // Safe column additions if table already existed without them
        try { connection.Execute("ALTER TABLE Deals ADD COLUMN DepositTxHash TEXT DEFAULT ''"); } catch {}
        try { connection.Execute("ALTER TABLE Deals ADD COLUMN DepositTimestamp TEXT DEFAULT ''"); } catch {}
        try { connection.Execute("ALTER TABLE Deals ADD COLUMN ShipTxHash TEXT DEFAULT ''"); } catch {}
        try { connection.Execute("ALTER TABLE Deals ADD COLUMN ShipTimestamp TEXT DEFAULT ''"); } catch {}
        try { connection.Execute("ALTER TABLE Deals ADD COLUMN ReleaseTxHash TEXT DEFAULT ''"); } catch {}
        try { connection.Execute("ALTER TABLE Deals ADD COLUMN ReleaseTimestamp TEXT DEFAULT ''"); } catch {}
        try { connection.Execute("ALTER TABLE Deals ADD COLUMN TargetBuyerWallet TEXT DEFAULT ''"); } catch {}
    }
}
