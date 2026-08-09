using GswapApp.Web.Services;
using MudBlazor.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();
builder.Services.AddServerSideBlazor(options =>
{
    options.DetailedErrors = true;
});

builder.Services.AddMudServices();

builder.Services.Configure<GswapSettings>(builder.Configuration.GetSection(GswapSettings.SectionName));
builder.Services.AddSingleton(sp => sp.GetRequiredService<Microsoft.Extensions.Options.IOptions<GswapSettings>>().Value);
builder.Services.AddScoped<WalletStateService>();
builder.Services.AddScoped<WalletConnectHelper>();
builder.Services.AddSingleton<GswapContractService>();

var app = builder.Build();

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
app.MapBlazorHub();
app.MapFallbackToPage("/_Host");

app.Run();
