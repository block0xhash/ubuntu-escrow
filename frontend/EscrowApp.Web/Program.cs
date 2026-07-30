using EscrowApp.Infra;
using EscrowApp.Web.Services;
using Microsoft.AspNetCore.Components;
using MudBlazor.Services;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddControllersWithViews();
builder.Services.AddRazorPages();
builder.Services.AddServerSideBlazor(options =>
{
    options.DetailedErrors = true;
});

// Register MudBlazor services (Dialogs, Snackbars, etc.)
builder.Services.AddMudServices();

// Register application state services
builder.Services.AddScoped<WalletStateService>();

// HttpClient for calling the app's own API controllers from Blazor Server components
builder.Services.AddScoped(sp =>
{
    var navigationManager = sp.GetRequiredService<NavigationManager>();
    return new HttpClient { BaseAddress = new Uri(navigationManager.BaseUri) };
});

// EscrowContractService reads the contract address/RPC from ContractSettings (single
// source of truth) rather than appsettings.json, since Infra can't reference Web types directly.
builder.Services.AddScoped(_ => new EscrowContractService(ContractSettings.RpcUrl, ContractSettings.EscrowContractAddress));

// Initialize the SQLite database and run migration updates
DatabaseInitializer.Initialize();

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseDeveloperExceptionPage();
}
else
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

if (!app.Environment.IsDevelopment())
{
    app.UseHttpsRedirection();
}

app.UseStaticFiles();

app.UseRouting();

app.MapGet("/health", () => Results.Ok("ok"));
app.MapRazorPages();
app.MapControllers();
app.MapBlazorHub();
app.MapFallbackToPage("/_Host");

app.Run();
