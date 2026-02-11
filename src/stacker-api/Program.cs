using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.AspNetCore.Authorization;
using Stacker.Api.Middleware;
using Stacker.AiConnector;
using Serilog;
using Serilog.Events;

// Configure Serilog before building the application
Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .MinimumLevel.Override("Microsoft.AspNetCore", LogEventLevel.Warning)
    .Enrich.FromLogContext()
    .Enrich.WithMachineName()
    .Enrich.WithEnvironmentName()
    .Enrich.WithThreadId()
    .Enrich.WithProperty("Application", "Stacker")
    .WriteTo.Console(outputTemplate: "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj} {Properties:j}{NewLine}{Exception}")
    .WriteTo.File(
        path: "logs/Stacker-.log",
        rollingInterval: RollingInterval.Day,
        outputTemplate: "{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz} [{Level:u3}] {Message:lj} {Properties:j}{NewLine}{Exception}",
        retainedFileCountLimit: 31)
    .CreateLogger();

try
{
    Log.Information("Starting Stacker API");

    var builder = WebApplication.CreateBuilder(args);

    // Replace default logging with Serilog
    builder.Host.UseSerilog();

    // Add Windows Authentication (Negotiate/Kerberos)
    builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme)
        .AddNegotiate();

    builder.Services.AddAuthorization();

    // Add Ollama AI connector for local LLM integration
    builder.Services.AddOllamaClient(
        builder.Configuration["Ollama:Endpoint"] ?? "http://localhost:11434");

    var app = builder.Build();

    // Enable correlation ID tracking (must be early in pipeline)
    app.UseCorrelationId();

    // Enable Serilog request logging
    app.UseSerilogRequestLogging(options =>
    {
        options.MessageTemplate = "HTTP {RequestMethod} {RequestPath} responded {StatusCode} in {Elapsed:0.0000} ms";
        options.EnrichDiagnosticContext = (diagnosticContext, httpContext) =>
        {
            diagnosticContext.Set("RequestHost", httpContext.Request.Host.Value);
            diagnosticContext.Set("UserAgent", httpContext.Request.Headers["User-Agent"].ToString());
            diagnosticContext.Set("UserName", httpContext.User.Identity?.Name ?? "Anonymous");
        };
    });

    // Enable authentication and authorization middleware
    app.UseAuthentication();
    app.UseAuthorization();

    // Root endpoint - shows IIS/ANCM is working
    app.MapGet("/", (HttpContext context) =>
    {
        var startTime = DateTime.UtcNow;
        var correlationId = context.GetCorrelationId();
        var userName = context.User.Identity?.Name ?? "Anonymous";

        Log.Information("API request started: {Action} {Resource} by {UserId} with {CorrelationId}",
            "GetRoot", "/", userName, correlationId);

        var result = Results.Ok(new
        {
            message = "OK from IIS/ANCM - Stacker at Towanda!",
            environment = app.Environment.EnvironmentName,
            timestamp = DateTime.UtcNow
        });

        var duration = (DateTime.UtcNow - startTime).TotalMilliseconds;
        Log.Information("API request completed: {Action} {Resource} {Result} in {Duration}ms by {UserId} with {CorrelationId}",
            "GetRoot", "/", "Success", duration, userName, correlationId);

        return result;
    });

    // Health check endpoint for monitoring
    app.MapGet("/health", (HttpContext context) =>
    {
        var startTime = DateTime.UtcNow;
        var correlationId = context.GetCorrelationId();

        Log.Debug("Health check started with {CorrelationId}", correlationId);

        var result = Results.Ok(new
        {
            status = "Healthy",
            application = "Stacker",
            environment = app.Environment.EnvironmentName,
            timestamp = DateTime.UtcNow
        });

        var duration = (DateTime.UtcNow - startTime).TotalMilliseconds;
        Log.Debug("Health check completed: {Result} in {Duration}ms with {CorrelationId}",
            "Healthy", duration, correlationId);

        return result;
    });

    // Environment info endpoint
    app.MapGet("/info", (IWebHostEnvironment env, HttpContext context) =>
    {
        var startTime = DateTime.UtcNow;
        var correlationId = context.GetCorrelationId();
        var userName = context.User.Identity?.Name ?? "Anonymous";

        Log.Information("Environment info request: {Action} {Resource} by {UserId} with {CorrelationId}",
            "GetInfo", "/info", userName, correlationId);

        var result = Results.Ok(new
        {
            applicationName = env.ApplicationName,
            environmentName = env.EnvironmentName,
            contentRootPath = env.ContentRootPath,
            webRootPath = env.WebRootPath
        });

        var duration = (DateTime.UtcNow - startTime).TotalMilliseconds;
        Log.Information("Environment info completed: {Action} {Resource} {Result} in {Duration}ms by {UserId} with {CorrelationId}",
            "GetInfo", "/info", "Success", duration, userName, correlationId);

        return result;
    });

    // User identity endpoint - requires authentication
    app.MapGet("/user", [Authorize] (HttpContext context) =>
    {
        var startTime = DateTime.UtcNow;
        var correlationId = context.GetCorrelationId();
        var userName = context.User.Identity?.Name ?? "Anonymous";
        var isAuthenticated = context.User.Identity?.IsAuthenticated ?? false;

        Log.Information("User identity request: {Action} {Resource} by {UserId} (authenticated: {IsAuthenticated}) with {CorrelationId}",
            "GetUser", "/user", userName, isAuthenticated, correlationId);

        var result = Results.Ok(new
        {
            isAuthenticated = isAuthenticated,
            userName = userName,
            authenticationType = context.User.Identity?.AuthenticationType ?? "None",
            timestamp = DateTime.UtcNow
        });

        var duration = (DateTime.UtcNow - startTime).TotalMilliseconds;
        Log.Information("User identity completed: {Action} {Resource} {Result} in {Duration}ms by {UserId} with {CorrelationId}",
            "GetUser", "/user", "Success", duration, userName, correlationId);

        return result;
    });

    // AI health endpoint - validates Ollama connectivity and model availability
    app.MapGet("/api/ai/health", async (OllamaClient ollamaClient, HttpContext context, ILogger<Program> logger) =>
    {
        var startTime = DateTime.UtcNow;
        var correlationId = context.GetCorrelationId();
        var userName = context.User.Identity?.Name ?? "Anonymous";

        logger.LogInformation("AI health check started: {Action} {Resource} by {UserId} with {CorrelationId}",
            "GetAiHealth", "/api/ai/health", userName, correlationId);

        try
        {
            // Check if Ollama is healthy
            var isHealthy = await ollamaClient.IsHealthyAsync(CancellationToken.None);

            if (!isHealthy)
            {
                var duration = (DateTime.UtcNow - startTime).TotalMilliseconds;
                logger.LogWarning("AI health check failed: {Action} {Resource} {Result} in {Duration}ms by {UserId} with {CorrelationId}",
                    "GetAiHealth", "/api/ai/health", "Unhealthy - Ollama not responding", duration, userName, correlationId);

                return Results.StatusCode(StatusCodes.Status503ServiceUnavailable);
            }

            var duration2 = (DateTime.UtcNow - startTime).TotalMilliseconds;
            logger.LogInformation("AI health check completed: {Action} {Resource} {Result} in {Duration}ms by {UserId} with {CorrelationId}",
                "GetAiHealth", "/api/ai/health", "Healthy", duration2, userName, correlationId);

            return Results.Ok(new
            {
                status = "Healthy",
                service = "Ollama",
                model = "llama3",
                endpoint = "http://localhost:11434",
                timestamp = DateTime.UtcNow,
                durationMs = duration2,
                correlationId = correlationId
            });
        }
        catch (Exception ex)
        {
            var duration = (DateTime.UtcNow - startTime).TotalMilliseconds;
            logger.LogError(ex, "AI health check error: {Action} {Resource} by {UserId} with {CorrelationId}: {Error}",
                "GetAiHealth", "/api/ai/health", userName, correlationId, ex.Message);

            return Results.StatusCode(StatusCodes.Status503ServiceUnavailable);
        }
    });

    Log.Information("Stacker API started successfully");
    app.Run();
}
catch (Exception ex)
{
    Log.Fatal(ex, "Stacker API failed to start");
    throw;
}
finally
{
    Log.CloseAndFlush();
}
