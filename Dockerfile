# ---- Build stage ----
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Copy project files first so NuGet restore is cached across builds
COPY frontend/EscrowApp.slnx ./frontend/EscrowApp.slnx
COPY frontend/EscrowApp.Core/EscrowApp.Core.csproj ./frontend/EscrowApp.Core/
COPY frontend/EscrowApp.Infra/EscrowApp.Infra.csproj ./frontend/EscrowApp.Infra/
COPY frontend/EscrowApp.Web/EscrowApp.Web.csproj ./frontend/EscrowApp.Web/

RUN dotnet restore frontend/EscrowApp.Web/EscrowApp.Web.csproj

# Copy the rest of the source and publish
COPY frontend/ ./frontend/
RUN dotnet publish frontend/EscrowApp.Web/EscrowApp.Web.csproj -c Release -o /app/publish --no-restore

# ---- Runtime stage ----
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app/publish .

ENV ASPNETCORE_ENVIRONMENT=Production
EXPOSE 8080

# Render (and most hosts) inject $PORT at runtime; fall back to 8080 for local/other platforms
CMD ASPNETCORE_URLS=http://+:${PORT:-8080} dotnet EscrowApp.Web.dll
