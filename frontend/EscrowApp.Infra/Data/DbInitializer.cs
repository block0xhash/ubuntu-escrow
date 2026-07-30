using Microsoft.Data.Sqlite;
using Dapper;

namespace EscrowApp.Infrastructure.Data
{
    public class DbInitializer
    {
        private readonly string _connectionString;

        public DbInitializer(string connectionString)
        {
            _connectionString = connectionString;
        }

        public void Initialize()
        {
            using var connection = new SqliteConnection(_connectionString);
            connection.Open();

            var createTableQuery = @"
                CREATE TABLE IF NOT EXISTS DealsMetadata (
                    DealId INTEGER PRIMARY KEY AUTOINCREMENT,
                    BuyerWallet TEXT NOT NULL,
                    SellerWallet TEXT NOT NULL,
                    Amount TEXT NOT NULL,
                    Status TEXT NOT NULL,
                    TransactionHash TEXT,
                    CreatedAt DATETIME DEFAULT CURRENT_TIMESTAMP
                );";

            connection.Execute(createTableQuery);
        }
    }
}
